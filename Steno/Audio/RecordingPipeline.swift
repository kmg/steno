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

    private(set) var systemAudioActive = false

    func start(
        audioURL: URL,
        streamer: StreamingTranscriber?,
        onSegmentsUpdated: @escaping @Sendable ([TranscriptionSegment], [TranscriptionSegment]) -> Void
    ) throws {
        state.reset()
        systemAudioActive = false

        // Start system audio
        do {
            systemCapture.bufferHandler = { [mixer, state] bufferList in
                if let samples = mixer.samplesFromBufferList(bufferList) {
                    state.appendSystemSamples(samples)
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

        // Set up mic handler (but don't start yet — writer needs to be ready first)
        mic.bufferHandler = { buffer in
            capturedStreamer?.appendBuffer(buffer)

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
                        // Use the buffer's format — MicrophoneCapture guarantees this
                        // matches the original recording format via its converter
                        if let mixedBuffer = RecordingPipeline.floatsToBuffer(mixed, format: buffer.format) {
                            capturedWriter.append(buffer: mixedBuffer)
                        } else {
                            capturedWriter.append(buffer: buffer)
                        }
                    } else {
                        capturedWriter.append(buffer: buffer)
                    }
                } else {
                    capturedWriter.append(buffer: buffer)
                }
            } else {
                capturedWriter.append(buffer: buffer)
            }
        }

        // Start mic to get the input format
        try mic.startWithHandler()

        guard let format = mic.inputFormat else {
            throw MicrophoneCapture.CaptureError.invalidFormat
        }

        recordingFormat = format

        // Start writer AFTER we know the format.
        // The mic is already delivering buffers, but the writer guards with isWriting
        // so the first few buffers (~1-2 at most) are dropped. This is unavoidable
        // since we need the mic's actual format to configure the writer.
        try writer.start(outputURL: audioURL, sourceFormat: format)

        // Start streaming
        if let streamer {
            streamer.onSegmentsUpdated = onSegmentsUpdated
        }

        logger.info("Recording pipeline started, systemAudio: \(self.systemAudioActive)")
    }

    func stop() {
        mic.stop()
        systemCapture.stop()
        writer.finish()
        state.reset()
        recordingFormat = nil
        systemAudioActive = false
    }

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
