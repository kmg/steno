import Foundation
import AVFoundation
import Accelerate
import os

@MainActor
final class RecordingManager: ObservableObject {
    @Published var isRecording = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var error: String?
    @Published private(set) var systemAudioActive = false

    private let mic = MicrophoneCapture()
    private let systemCapture = SystemAudioCapture()
    private let mixer = AudioMixer()
    private let writer = AudioFileWriter()
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "RecordingManager")

    private var timer: Timer?
    private var recordingStart: Date?
    private(set) var lastSession: Session?
    private var streamingTranscriber: StreamingTranscriber?
    private var streamingTask: Task<Void, Never>?

    // System audio sample ring buffer (written from IO callback, read from mic callback)
    private var systemSampleBuffer: [Float] = []
    private var micSampleBuffer: [Float] = []
    private let bufferLock = NSLock()
    private var systemAudioReady = false
    private var writerStarted = false
    private var micCallbackCount = 0

    func startRecording(sessionStore: SessionStore, transcriptionEngine: TranscriptionEngine, diarizationManager: DiarizationManager) {
        guard !isRecording else { return }

        let session = sessionStore.startSession()
        let audioURL = sessionStore.audioFileURL(for: session)
        let diarizer = diarizationManager.streamDiarizer

        diarizationManager.reset()

        do {
            let streamer = transcriptionEngine.makeStreamingTranscriber(sampleRate: 16000)
            self.streamingTranscriber = streamer

            // Always try system audio — silently skip if it fails
            systemAudioActive = false
            do {
                systemCapture.bufferHandler = { [weak self] bufferList in
                    guard let self else { return }
                    if let samples = self.mixer.samplesFromBufferList(bufferList) {
                        self.bufferLock.lock()
                        self.systemSampleBuffer.append(contentsOf: samples)
                        if !self.systemAudioReady { self.systemAudioReady = true }
                        self.bufferLock.unlock()
                    }
                }
                try systemCapture.start()
                systemAudioActive = true
                diarizationManager.systemAudioActive = true
                logger.info("System audio capture active")
            } catch {
                logger.info("System audio not available: \(error.localizedDescription)")
            }

            let captureSystemAudio = self.systemAudioActive

            try mic.start { [weak self] buffer, _ in
                guard let self else { return }

                // Send original mic-only buffer to streaming transcriber
                streamer?.appendBuffer(buffer)

                // Wait for system audio before writing, to avoid silence at start
                // Skip first ~10 mic callbacks (~0.5s) to let system audio tap start
                if captureSystemAudio && !self.writerStarted {
                    self.micCallbackCount += 1
                    self.bufferLock.lock()
                    let ready = self.systemAudioReady
                    self.bufferLock.unlock()
                    if !ready && self.micCallbackCount < 10 {
                        return // skip this buffer, streamer already got it above
                    }
                    self.writerStarted = true
                }

                if captureSystemAudio, let floatData = buffer.floatChannelData {
                    let frameCount = Int(buffer.frameLength)
                    let micSamples = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))

                    // Grab matching system audio samples
                    self.bufferLock.lock()
                    let availableSystem = min(frameCount, self.systemSampleBuffer.count)
                    let sysSamples: [Float]
                    if availableSystem > 0 {
                        sysSamples = Array(self.systemSampleBuffer.prefix(availableSystem))
                        self.systemSampleBuffer.removeFirst(availableSystem)
                    } else {
                        sysSamples = []
                    }

                    // Collect for diarization energy snapshots
                    self.micSampleBuffer.append(contentsOf: micSamples)
                    let sampleRate = buffer.format.sampleRate
                    let snapshotSize = Int(sampleRate * 0.25)
                    var micChunkForDiar: [Float]?
                    var sysChunkForDiar: [Float]?
                    if self.micSampleBuffer.count >= snapshotSize {
                        micChunkForDiar = Array(self.micSampleBuffer.prefix(snapshotSize))
                        sysChunkForDiar = sysSamples // approximate
                        self.micSampleBuffer.removeFirst(min(snapshotSize, self.micSampleBuffer.count))
                    }
                    self.bufferLock.unlock()

                    // Mix system audio into mic buffer for recording
                    if !sysSamples.isEmpty {
                        let mixed = self.mixer.mix(micSamples: micSamples, systemSamples: sysSamples)
                        // Write mixed audio to file
                        if let mixedBuffer = self.floatsToBuffer(mixed, format: buffer.format) {
                            self.writer.append(buffer: mixedBuffer)
                        } else {
                            self.writer.append(buffer: buffer)
                        }
                    } else {
                        self.writer.append(buffer: buffer)
                    }

                    // Record diarization energy
                    if let micChunk = micChunkForDiar {
                        let elapsed = Date().timeIntervalSince(self.recordingStart ?? Date())
                        diarizer.recordEnergy(micSamples: micChunk, systemSamples: sysChunkForDiar ?? [], timestamp: elapsed)
                    }
                } else {
                    // No system audio — write mic directly
                    self.writer.append(buffer: buffer)
                }
            }

            guard let format = mic.inputFormat else {
                throw MicrophoneCapture.CaptureError.invalidFormat
            }

            try writer.start(outputURL: audioURL, sourceFormat: format)

            isRecording = true
            recordingStart = Date()
            lastSession = session
            error = nil
            startTimer()

            transcriptionEngine.startStreaming()
            if let streamer {
                streamer.onSegmentsUpdated = { [weak transcriptionEngine] confirmed, unconfirmed in
                    Task { @MainActor in
                        transcriptionEngine?.updateLiveSegments(confirmed: confirmed, unconfirmed: unconfirmed)
                    }
                }
                streamingTask = Task.detached {
                    await streamer.start()
                }
            }

            logger.info("Recording started: \(session.id), systemAudio: \(self.systemAudioActive)")

        } catch {
            mic.stop()
            systemCapture.stop()
            self.error = error.localizedDescription
            logger.error("Failed to start recording: \(error)")
        }
    }

    func stopRecording(sessionStore: SessionStore, transcriptionEngine: TranscriptionEngine, diarizationManager: DiarizationManager) -> (session: Session, duration: TimeInterval)? {
        guard isRecording, let session = lastSession else { return nil }

        streamingTranscriber?.stop()
        streamingTask?.cancel()
        let allSegments = streamingTranscriber?.allSegments() ?? []

        mic.stop()
        systemCapture.stop()
        writer.finish()
        stopTimer()

        let duration = elapsedTime
        isRecording = false
        sessionStore.finishSession(duration: duration)

        if var transcript = transcriptionEngine.finalizeStreaming(allSegments: allSegments, duration: duration) {
            let audioURL = sessionStore.audioFileURL(for: session)
            diarizationManager.applySpeakerLabels(to: &transcript, audioFileURL: audioURL)
            sessionStore.saveTranscript(transcript, for: session)
        }

        logger.info("Recording stopped, duration: \(duration)s, segments: \(allSegments.count)")

        elapsedTime = 0
        recordingStart = nil
        streamingTranscriber = nil
        streamingTask = nil
        systemAudioActive = false
        writerStarted = false
        micCallbackCount = 0
        bufferLock.lock()
        systemSampleBuffer = []
        micSampleBuffer = []
        systemAudioReady = false
        bufferLock.unlock()

        return (session, duration)
    }

    // MARK: - Helpers

    /// Convert a [Float] array back to an AVAudioPCMBuffer matching the given format.
    nonisolated private func floatsToBuffer(_ floats: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(floats.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData else { return nil }
        let channels = Int(format.channelCount)

        // Write mono data to all channels
        for ch in 0..<channels {
            floats.withUnsafeBufferPointer { ptr in
                channelData[ch].initialize(from: ptr.baseAddress!, count: Int(frameCount))
            }
        }
        return buffer
    }

    // MARK: - Timer

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStart else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
