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

    private var systemSampleBuffer: [Float] = []
    private let bufferLock = NSLock()
    private var systemAudioReady = false
    private var writerStarted = false
    private var micCallbackCount = 0

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
            let localBufferLock = self.bufferLock
            do {
                systemCapture.bufferHandler = { [weak self] bufferList in
                    if let samples = localMixer.samplesFromBufferList(bufferList) {
                        localBufferLock.lock()
                        self?.systemSampleBuffer.append(contentsOf: samples)
                        if self?.systemAudioReady == false { self?.systemAudioReady = true }
                        localBufferLock.unlock()
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
            try mic.start { [weak self] buffer, _ in
                streamer?.appendBuffer(buffer)

                // Wait for system audio before writing, to avoid silence at start
                if captureSystemAudio {
                    guard let self else { return }
                    if !self.writerStarted {
                        self.micCallbackCount += 1
                        localBufferLock.lock()
                        let ready = self.systemAudioReady
                        localBufferLock.unlock()
                        if !ready && self.micCallbackCount < 10 {
                            return
                        }
                        self.writerStarted = true
                    }

                    if let floatData = buffer.floatChannelData {
                        let frameCount = Int(buffer.frameLength)
                        let micSamples = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))

                        localBufferLock.lock()
                        let availableSystem = min(frameCount, self.systemSampleBuffer.count)
                        let sysSamples: [Float]
                        if availableSystem > 0 {
                            sysSamples = Array(self.systemSampleBuffer.prefix(availableSystem))
                            self.systemSampleBuffer.removeFirst(availableSystem)
                        } else {
                            sysSamples = []
                        }
                        localBufferLock.unlock()

                        if !sysSamples.isEmpty {
                            let mixed = localMixer.mix(micSamples: micSamples, systemSamples: sysSamples)
                            if let mixedBuffer = self.floatsToBuffer(mixed, format: buffer.format) {
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
        writerStarted = false
        micCallbackCount = 0
        bufferLock.lock()
        systemSampleBuffer = []
        systemAudioReady = false
        bufferLock.unlock()

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
