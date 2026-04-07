import Foundation
import AVFoundation
import WhisperKit
import os

@MainActor
final class RecordingManager: ObservableObject {
    @Published var isRecording = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var error: String?
    @Published private(set) var systemAudioActive = false

    private let pipeline = RecordingPipeline()
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "RecordingManager")

    private var timer: Timer?
    private var recordingStart: Date?
    private(set) var lastSession: Session?
    private var streamingTranscriber: StreamingTranscriber?
    private var streamingTask: Task<Void, Never>?

    func startRecording(sessionStore: SessionStore, transcriptionEngine: TranscriptionEngine, diarizationManager: DiarizationManager) {
        guard !isRecording else { return }

        let session = sessionStore.startSession()
        let audioURL = sessionStore.audioFileURL(for: session)

        do {
            let streamer = transcriptionEngine.makeStreamingTranscriber(sampleRate: 16000)
            self.streamingTranscriber = streamer

            try pipeline.start(
                audioURL: audioURL,
                streamer: streamer,
                onSegmentsUpdated: { [weak transcriptionEngine] confirmed, unconfirmed in
                    Task { @MainActor in
                        transcriptionEngine?.updateLiveSegments(confirmed: confirmed, unconfirmed: unconfirmed)
                    }
                }
            )

            systemAudioActive = pipeline.systemAudioActive
            isRecording = true
            recordingStart = Date()
            lastSession = session
            error = nil
            startTimer()

            transcriptionEngine.startStreaming()
            if let streamer {
                streamingTask = Task.detached {
                    await streamer.start()
                }
            }

            logger.info("Recording started: \(session.id), systemAudio: \(self.systemAudioActive)")

        } catch {
            pipeline.stop()
            self.error = error.localizedDescription
            logger.error("Failed to start recording: \(error)")
            Analytics.captureError(error, context: ["action": "start_recording"])
        }
    }

    func stopRecording(sessionStore: SessionStore, transcriptionEngine: TranscriptionEngine, diarizationManager: DiarizationManager) -> (session: Session, duration: TimeInterval)? {
        guard isRecording, let session = lastSession else { return nil }

        streamingTranscriber?.stop()
        streamingTask?.cancel()
        let allSegments = streamingTranscriber?.allSegments() ?? []

        pipeline.stop()
        stopTimer()

        let duration = elapsedTime
        isRecording = false
        sessionStore.finishSession(duration: duration)

        if let transcript = transcriptionEngine.finalizeStreaming(allSegments: allSegments, duration: duration) {
            let audioURL = sessionStore.audioFileURL(for: session)
            // Save transcript immediately so user sees it right away
            sessionStore.saveTranscript(transcript, for: session)
            // Run diarization in background — updates transcript when done
            Task {
                var labeled = transcript
                diarizationManager.applySpeakerLabels(to: &labeled, audioFileURL: audioURL)
                sessionStore.saveTranscript(labeled, for: session)
            }
        }

        Analytics.recordingStopped(duration: duration, model: transcriptionEngine.modelName)
        logger.info("Recording stopped, duration: \(duration)s, segments: \(allSegments.count)")

        elapsedTime = 0
        recordingStart = nil
        streamingTranscriber = nil
        streamingTask = nil
        systemAudioActive = false

        return (session, duration)
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
