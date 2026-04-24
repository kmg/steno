import AVFoundation
import Accelerate
import WhisperKit
import os

/// Handles all audio thread work outside of @MainActor.
/// Owns mic capture, system audio capture, mixing, and file writing.
/// RecordingManager delegates to this class and only holds @Published UI state.
final class RecordingPipeline: @unchecked Sendable {
    private let mic = MicrophoneCapture()
    private let systemCapture = SystemAudioCapture()
    private let mixer = AudioMixer()
    private let writer = AudioFileWriter()
    private let state = AudioSharedState()
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "RecordingPipeline")

    /// The format used to open the file writer. All audio must match this.
    private var recordingFormat: AVAudioFormat?

    /// Base URL for the session folder. Used to create segment WAV files on device change.
    private var sessionFolderURL: URL?
    /// Tracks WAV segment files created during recording (for post-recording merge).
    private(set) var segmentURLs: [URL] = []
    private var segmentIndex = 0

    /// Accumulates raw system audio samples at their native rate (before resampling).
    /// The IO proc writes here; the resample timer reads and converts.
    private let rawSystemBuffer = RawAudioBuffer()

    /// Resamples system audio from system rate to mic rate on a dispatch queue
    /// (not on the real-time IO thread). AVAudioConverter may allocate internally,
    /// so it must NOT run on the audio thread.
    private var resampleTimer: DispatchSourceTimer?
    private let resampleQueue = DispatchQueue(label: "com.kmganesh.steno.resample", qos: .userInteractive)
    private var systemConverter: AVAudioConverter?
    private var systemInputFormat: AVAudioFormat?
    private var systemOutputFormat: AVAudioFormat?

    private(set) var systemAudioActive = false

    func start(
        audioURL: URL,
        streamer: StreamingTranscriber?,
        onSegmentsUpdated: @escaping @Sendable ([TranscriptionSegment], [TranscriptionSegment]) -> Void
    ) throws {
        state.reset()
        rawSystemBuffer.reset()
        systemAudioActive = false

        // Start system audio — IO proc writes raw samples to rawSystemBuffer
        do {
            let capturedRawBuffer = rawSystemBuffer
            let capturedMixer = mixer
            systemCapture.bufferHandler = { bufferList in
                if let samples = capturedMixer.samplesFromBufferList(bufferList) {
                    capturedRawBuffer.append(samples)
                }
            }
            try systemCapture.start()
            systemAudioActive = true
            logger.info("System audio capture active")
        } catch {
            logger.info("System audio not available: \(error.localizedDescription)")
        }

        let captureSystem = systemAudioActive

        // Capture everything explicitly — no implicit captures, no self
        let capturedWriter = writer
        let capturedMixer = mixer
        let capturedState = state
        let capturedStreamer = streamer

        // Set up mic handler
        mic.bufferHandler = { buffer in
            if captureSystem {
                if !capturedState.writerStarted {
                    capturedState.callbackCount += 1
                    if !capturedState.isReady && capturedState.callbackCount < 10 {
                        return
                    }
                    capturedState.writerStarted = true
                }

                if let floatData = buffer.floatChannelData {
                    let frameCount = Int(buffer.frameLength)
                    let micSamples = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))
                    let sysSamples = capturedState.consumeSystemSamples(count: frameCount)

                    if !sysSamples.isEmpty {
                        let mixed = capturedMixer.mix(micSamples: micSamples, systemSamples: sysSamples)
                        if let mixedBuffer = RecordingPipeline.floatsToBuffer(mixed, format: buffer.format) {
                            capturedStreamer?.appendBuffer(mixedBuffer)
                            capturedWriter.append(buffer: mixedBuffer)
                        } else {
                            capturedStreamer?.appendBuffer(buffer)
                            capturedWriter.append(buffer: buffer)
                        }
                    } else {
                        capturedStreamer?.appendBuffer(buffer)
                        capturedWriter.append(buffer: buffer)
                    }
                } else {
                    capturedStreamer?.appendBuffer(buffer)
                    capturedWriter.append(buffer: buffer)
                }
            } else {
                capturedStreamer?.appendBuffer(buffer)
                capturedWriter.append(buffer: buffer)
            }
        }

        // Start mic to get the input format
        try mic.startWithHandler()

        guard let format = mic.inputFormat else {
            throw MicrophoneCapture.CaptureError.invalidFormat
        }

        recordingFormat = format
        sessionFolderURL = audioURL.deletingLastPathComponent()
        segmentURLs = [audioURL]
        segmentIndex = 0

        // Configure system audio resampling now that mic format is known.
        configureSystemResampling(micRate: format.sampleRate)
        if systemAudioActive {
            startResampleTimer()
        }

        // Start writer AFTER we know the format.
        try writer.start(outputURL: audioURL, sourceFormat: format)

        // Handle mic device changes: close current WAV, open new segment at new format.
        // No real-time resampling — each segment is at its native rate.
        // Post-recording merge (AVFoundation) handles format conversion.
        mic.onDeviceChange = { [weak self] newFormat in
            guard let self, let folder = self.sessionFolderURL else { return }

            // Close current segment
            self.writer.finish()

            // Open new segment at the new format
            self.segmentIndex += 1
            let segURL = folder.appendingPathComponent("audio-seg\(self.segmentIndex).wav")
            self.segmentURLs.append(segURL)
            do {
                try self.writer.start(outputURL: segURL, sourceFormat: newFormat)
                self.logger.info("New WAV segment at \(newFormat.sampleRate)Hz (\(segURL.lastPathComponent))")
            } catch {
                self.logger.error("Failed to start new WAV segment: \(error.localizedDescription)")
            }

            // Reconfigure system audio resampling for new mic rate
            self.configureSystemResampling(micRate: newFormat.sampleRate)
        }

        // Start streaming
        if let streamer {
            streamer.onSegmentsUpdated = onSegmentsUpdated
        }

        logger.info("Recording pipeline started, systemAudio: \(self.systemAudioActive)")
    }

    func stop() {
        stopResampleTimer()
        mic.stop()
        systemCapture.stop()
        writer.finish()
        state.reset()
        rawSystemBuffer.reset()
        systemConverter = nil
        systemInputFormat = nil
        systemOutputFormat = nil
        recordingFormat = nil
        sessionFolderURL = nil
        segmentIndex = 0
        systemAudioActive = false
    }

    /// Configure AVAudioConverter for system→mic rate conversion.
    /// Called at recording start and after mic device changes.
    /// Synchronizes with the resample queue to avoid racing on the converter.
    private func configureSystemResampling(micRate: Double) {
        guard systemAudioActive, let sysFormat = systemCapture.captureFormat else { return }
        let sysRate = sysFormat.sampleRate

        // Drain any stale samples at the old rate before reconfiguring
        rawSystemBuffer.reset()

        if abs(sysRate - micRate) > 1 {
            let inFmt = AVAudioFormat(standardFormatWithSampleRate: sysRate, channels: 1)!
            let outFmt = AVAudioFormat(standardFormatWithSampleRate: micRate, channels: 1)!
            let newConverter = AVAudioConverter(from: inFmt, to: outFmt)
            resampleQueue.sync {
                self.systemConverter = newConverter
                self.systemInputFormat = inFmt
                self.systemOutputFormat = outFmt
            }
            logger.info("System audio resampling: \(sysRate)Hz → \(micRate)Hz")
        } else {
            resampleQueue.sync {
                self.systemConverter = nil
                self.systemInputFormat = nil
                self.systemOutputFormat = nil
            }
            logger.info("System audio: same rate as mic (\(sysRate)Hz), passthrough")
        }
    }

    // MARK: - Resample Timer

    /// Runs every 5ms on a dispatch queue. Drains raw system audio samples,
    /// resamples to mic rate via AVAudioConverter, appends to AudioSharedState.
    private func startResampleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: resampleQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))

        let capturedRawBuffer = rawSystemBuffer
        let capturedState = state

        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let raw = capturedRawBuffer.drain()
            guard !raw.isEmpty else { return }

            if let converter = self.systemConverter,
               let inFmt = self.systemInputFormat,
               let outFmt = self.systemOutputFormat {
                // Resample from system rate to mic rate
                let resampled = Self.resampleSamples(raw, converter: converter, inputFormat: inFmt, outputFormat: outFmt)
                capturedState.appendSystemSamples(resampled)
            } else {
                // Same rate — passthrough
                capturedState.appendSystemSamples(raw)
            }
        }

        timer.resume()
        resampleTimer = timer
    }

    private func stopResampleTimer() {
        resampleTimer?.cancel()
        resampleTimer = nil
    }

    /// Resample float samples using AVAudioConverter. Called on the resample dispatch queue,
    /// NOT on the audio IO thread.
    private static func resampleSamples(
        _ samples: [Float],
        converter: AVAudioConverter,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat
    ) -> [Float] {
        let frameCount = AVAudioFrameCount(samples.count)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            return samples
        }
        inBuf.frameLength = frameCount

        // Copy samples into input buffer
        if let channelData = inBuf.floatChannelData {
            samples.withUnsafeBufferPointer { ptr in
                channelData[0].initialize(from: ptr.baseAddress!, count: samples.count)
            }
        }

        // Calculate output frame count
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outFrameCount = AVAudioFrameCount(ceil(Double(frameCount) * ratio))
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outFrameCount + 16) else {
            return samples
        }

        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inBuf
        }

        guard outBuf.frameLength > 0, let outData = outBuf.floatChannelData else {
            return samples
        }

        return Array(UnsafeBufferPointer(start: outData[0], count: Int(outBuf.frameLength)))
    }

    // MARK: - Buffer Utilities

    static func floatsToBuffer(_ floats: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(floats.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData else { return nil }
        let channels = Int(format.channelCount)

        for ch in 0..<channels {
            floats.withUnsafeBufferPointer { ptr in
                channelData[ch].initialize(from: ptr.baseAddress!, count: Int(frameCount))
            }
        }
        return buffer
    }
}

// MARK: - RawAudioBuffer

/// Simple lock-protected buffer for accumulating raw float samples.
/// Written by the system audio IO proc, drained by the resample timer.
final class RawAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ s: [Float]) {
        lock.lock()
        samples.append(contentsOf: s)
        lock.unlock()
    }

    /// Drain all accumulated samples. Returns empty array if none available.
    func drain() -> [Float] {
        lock.lock()
        let result = samples
        samples = []
        lock.unlock()
        return result
    }

    func reset() {
        lock.lock()
        samples = []
        lock.unlock()
    }
}
