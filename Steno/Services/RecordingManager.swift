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

    private let sharedState = AudioSharedState()

    func startRecording(sessionStore: SessionStore, transcriptionEngine: TranscriptionEngine, diarizationManager: DiarizationManager) {
        guard !isRecording else { return }

        let session = sessionStore.startSession()
        let audioURL = sessionStore.audioFileURL(for: session)

        do {
            let streamer = transcriptionEngine.makeStreamingTranscriber(sampleRate: 16000)
            self.streamingTranscriber = streamer

            // Always try system audio — silently skip if it fails
            systemAudioActive = false
            let localMixer = self.mixer
            let state = self.sharedState
            do {
                systemCapture.bufferHandler = { bufferList in
                    if let samples = localMixer.samplesFromBufferList(bufferList) {
                        state.appendSystemSamples(samples)
                    }
                }
                try systemCapture.start()
                systemAudioActive = true
                logger.info("System audio capture active")
            } catch {
                logger.info("System audio not available: \(error.localizedDescription)")
            }

            let captureSystemAudio = self.systemAudioActive

            let localWriter = self.writer
            let toBuffer = self.floatsToBuffer
            try mic.start { buffer, _ in
                streamer?.appendBuffer(buffer)

                if captureSystemAudio {
                    // Wait for system audio before writing
                    if !state.writerStarted {
                        state.callbackCount += 1
                        if !state.isReady && state.callbackCount < 10 {
                            return
                        }
                        state.writerStarted = true
                    }

                    if let floatData = buffer.floatChannelData {
                        let frameCount = Int(buffer.frameLength)
                        let micSamples = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))
                        let sysSamples = state.consumeSystemSamples(count: frameCount)

                        if !sysSamples.isEmpty {
                            let mixed = localMixer.mix(micSamples: micSamples, systemSamples: sysSamples)
                            if let mixedBuffer = toBuffer(mixed, buffer.format) {
                                localWriter.append(buffer: mixedBuffer)
                            } else {
                                localWriter.append(buffer: buffer)
                            }
                        } else {
                            localWriter.append(buffer: buffer)
                        }
                    } else {
                        localWriter.append(buffer: buffer)
                    }
                } else {
                    localWriter.append(buffer: buffer)
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
        sharedState.reset()

        return (session, duration)
    }

    // MARK: - Helpers

    nonisolated private func floatsToBuffer(_ floats: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
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
