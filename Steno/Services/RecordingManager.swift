import Foundation
import AVFoundation
import WhisperKit
import os

@MainActor
final class RecordingManager: ObservableObject {
    @Published var isRecording = false
    @Published var isStarting = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var error: String?
    @Published private(set) var systemAudioActive = false

    private let pipeline = RecordingPipeline()
    private let log = StenoLog.app

    private var timer: Timer?
    private var partialSaveTimer: Timer?
    private var recordingStart: Date?
    private(set) var lastSession: Session?
    private var streamingTranscriber: StreamingTranscriber?
    private var streamingTask: Task<Void, Never>?
    private weak var activeSessionStore: SessionStore?
    private weak var activeTranscriptionEngine: TranscriptionEngine?

    func startRecording(sessionStore: SessionStore, transcriptionEngine: TranscriptionEngine, diarizationManager: DiarizationManager) {
        guard !isRecording && !isStarting else { return }

        let session = sessionStore.startSession()
        let audioURL = sessionStore.recordingFileURL(for: session)
        let streamer = transcriptionEngine.makeStreamingTranscriber(sampleRate: 16000)

        // UI state: show starting spinner immediately, guard against re-click.
        isStarting = true
        error = nil
        lastSession = session
        activeSessionStore = sessionStore
        activeTranscriptionEngine = transcriptionEngine

        let pipeline = self.pipeline
        let onSegmentsUpdated: @Sendable ([TranscriptionSegment], [TranscriptionSegment]) -> Void = { [weak transcriptionEngine] confirmed, unconfirmed in
            Task { @MainActor in
                transcriptionEngine?.updateLiveSegments(confirmed: confirmed, unconfirmed: unconfirmed)
            }
        }

        // If mic restart fails during recording (device change crash),
        // stop recording gracefully and notify user.
        pipeline.onRecordingInterrupted = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.error = "Recording stopped — audio device changed"
                if let result = self.stopRecording(
                    sessionStore: sessionStore,
                    transcriptionEngine: transcriptionEngine,
                    diarizationManager: diarizationManager
                ) {
                    self.log.info("Recording auto-stopped after device change, duration: \(result.duration)s")
                }
            }
        }

        // Core Audio setup (AudioDeviceCreateIOProcIDWithBlock) can block on XPC to
        // coreaudiod for seconds. Do it off the main thread to prevent 2s app hangs.
        Task {
            do {
                try await Task.detached {
                    try pipeline.start(
                        audioURL: audioURL,
                        streamer: streamer,
                        onSegmentsUpdated: onSegmentsUpdated
                    )
                }.value

                // Back on main actor after pipeline.start() completes
                self.streamingTranscriber = streamer
                self.systemAudioActive = pipeline.systemAudioActive
                self.recordingStart = Date()
                self.isRecording = true
                self.isStarting = false
                self.startTimer()
                self.startPartialSaveTimer()

                if let streamer {
                    transcriptionEngine.startStreaming()
                    self.streamingTask = Task.detached {
                        await streamer.start()
                    }
                }

                self.log.info("Recording started: \(session.id), systemAudio: \(self.systemAudioActive)")
            } catch {
                pipeline.stop()
                self.isStarting = false
                self.isRecording = false
                self.lastSession = nil
                self.activeSessionStore = nil
                self.activeTranscriptionEngine = nil
                self.error = error.localizedDescription
                self.log.error("Failed to start recording: \(error)")
                Analytics.captureError(error, context: ["action": "start_recording"])
            }
        }
    }

    func stopRecording(sessionStore: SessionStore, transcriptionEngine: TranscriptionEngine, diarizationManager: DiarizationManager) -> (session: Session, duration: TimeInterval)? {
        guard isRecording, let session = lastSession else { return nil }

        streamingTranscriber?.stop()
        streamingTask?.cancel()
        let allSegments = streamingTranscriber?.allSegments() ?? []

        pipeline.stop()
        stopTimer()
        stopPartialSaveTimer()

        let duration = elapsedTime
        isRecording = false
        sessionStore.finishSession(duration: duration)

        // Convert WAV → AAC in background. Diarization proceeds using the .wav
        // immediately; audioFileURL will prefer .m4a once conversion completes.
        let wavURL = sessionStore.recordingFileURL(for: session)
        Task.detached {
            await AudioConverter.convertToAAC(wavURL: wavURL)
        }

        if let transcript = transcriptionEngine.finalizeStreaming(allSegments: allSegments, duration: duration) {
            let audioURL = sessionStore.audioFileURL(for: session)
            // Save transcript immediately so user sees it right away
            sessionStore.saveTranscript(transcript, for: session)
            // Run diarization off the main thread. `Task.detached` is essential —
            // a plain `Task {}` inherits MainActor and hangs the UI for the full
            // duration of CoreML inference (seconds to tens of seconds).
            let dm = diarizationManager
            let store = sessionStore
            Task.detached {
                let labeled = dm.applyingSpeakerLabels(to: transcript, audioFileURL: audioURL)
                await store.saveTranscript(labeled, for: session)
            }
        }

        Analytics.recordingStopped(duration: duration, model: transcriptionEngine.modelName)
        log.info("Recording stopped, duration: \(duration)s, segments: \(allSegments.count)")

        elapsedTime = 0
        recordingStart = nil
        streamingTranscriber = nil
        streamingTask = nil
        systemAudioActive = false
        activeSessionStore = nil
        activeTranscriptionEngine = nil

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

    // MARK: - Partial Transcript Save

    private func startPartialSaveTimer() {
        partialSaveTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.savePartialTranscript()
            }
        }
    }

    private func stopPartialSaveTimer() {
        partialSaveTimer?.invalidate()
        partialSaveTimer = nil
    }

    private func savePartialTranscript() {
        guard let session = lastSession,
              let sessionStore = activeSessionStore,
              let transcriptionEngine = activeTranscriptionEngine else { return }
        let segments = transcriptionEngine.liveConfirmedSegments + transcriptionEngine.liveUnconfirmedSegments
        guard !segments.isEmpty else { return }

        let transcript = Transcript.from(
            whisperSegments: segments,
            duration: elapsedTime,
            model: transcriptionEngine.modelName,
            language: "en"
        )
        sessionStore.saveLiveTranscript(transcript, for: session)
    }
}
