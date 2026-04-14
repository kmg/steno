import Foundation
import WhisperKit
import os

@MainActor
final class TranscriptionEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(String)
        case loading(String)
        case transcribing(Float)
        case streaming
        case complete
        case error(String)
    }

    @Published var state: State = .idle
    @Published var activeSessionID: String?
    @Published var lastTranscript: Transcript?
    @Published var liveConfirmedSegments: [TranscriptionSegment] = []
    @Published var liveUnconfirmedSegments: [TranscriptionSegment] = []

    private let worker = TranscriptionWorker()
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "TranscriptionEngine")

    var modelName: String = "large-v3_turbo"
    var customModelFolder: String?

    func loadModel() async {
        let cached = isModelCached(modelName)
        state = cached ? .loading(modelName) : .downloading(modelName)
        logger.info("Loading WhisperKit model: \(self.modelName), cached: \(cached)")

        do {
            try await worker.load(model: modelName, modelFolder: customModelFolder)
            state = .idle
            logger.info("WhisperKit model loaded: \(self.modelName)")
        } catch {
            state = .error("Failed to load model: \(error.localizedDescription)")
            logger.error("Failed to load WhisperKit: \(error)")
            Analytics.captureError(error, context: ["action": "load_model", "model": modelName])
        }
    }

    private func isModelCached(_ model: String) -> Bool {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil
        ) else { return false }
        return contents.contains { $0.lastPathComponent.contains("WhisperKit") }
    }

    /// Create a streaming transcriber using the loaded WhisperKit instance.
    func makeStreamingTranscriber(sampleRate: Double) -> StreamingTranscriber? {
        guard let pipe = worker.whisperKit else { return nil }
        return StreamingTranscriber(whisperKit: pipe, sampleRate: sampleRate)
    }

    /// Start live streaming mode.
    func startStreaming() {
        state = .streaming
        liveConfirmedSegments = []
        liveUnconfirmedSegments = []
        lastTranscript = nil
    }

    /// Update live segments from streaming transcriber callback.
    func updateLiveSegments(confirmed: [TranscriptionSegment], unconfirmed: [TranscriptionSegment]) {
        liveConfirmedSegments = confirmed
        liveUnconfirmedSegments = unconfirmed
    }

    /// Finalize streaming: convert live segments to a Transcript.
    func finalizeStreaming(allSegments: [TranscriptionSegment], duration: Double) -> Transcript? {
        guard !allSegments.isEmpty else {
            state = .complete
            return nil
        }

        let transcript = Transcript.from(
            whisperSegments: allSegments,
            duration: duration,
            model: modelName,
            language: "en"
        )

        lastTranscript = transcript
        liveConfirmedSegments = []
        liveUnconfirmedSegments = []
        state = .complete
        return transcript
    }

    /// Transcribe a saved audio file (for re-transcription or non-streaming fallback).
    func transcribe(audioPath: String, duration: Double, sessionID: String? = nil) async -> Transcript? {
        activeSessionID = sessionID
        state = .transcribing(0)
        logger.info("Transcribing: \(audioPath)")

        do {
            let audioDuration = max(duration, 1)
            let expectedWindows = Int(ceil(audioDuration / 30.0))
            let result = try await worker.transcribe(audioPath: audioPath) { progress in
                let pct = Float(min(Double(progress.windowId + 1) / Double(expectedWindows), 0.99))
                Task { @MainActor in
                    self.state = .transcribing(pct)
                }
                return nil // continue transcription
            }

            guard let result else {
                state = .error("No transcription result")
                return nil
            }

            let transcript = Transcript.from(
                whisperSegments: result.segments,
                duration: duration,
                model: modelName,
                language: result.language
            )

            lastTranscript = transcript
            activeSessionID = nil
            state = .complete
            logger.info("Transcription complete: \(result.segments.count) segments")
            return transcript

        } catch {
            activeSessionID = nil
            state = .error("Transcription failed: \(error.localizedDescription)")
            logger.error("Transcription failed: \(error)")
            Analytics.captureError(error, context: ["action": "transcribe_file"])
            return nil
        }
    }
}

/// Non-isolated worker that owns WhisperKit to avoid Sendable issues.
final class TranscriptionWorker: @unchecked Sendable {
    private(set) var whisperKit: WhisperKit?

    func load(model: String, modelFolder: String? = nil) async throws {
        let config = WhisperKitConfig(
            model: model == "custom" ? nil : model,
            modelFolder: modelFolder,
            verbose: false,
            prewarm: false,
            load: true,
            download: modelFolder == nil
        )
        whisperKit = try await WhisperKit(config)
    }

    func transcribe(
        audioPath: String,
        callback: @escaping @Sendable (TranscriptionProgress) -> Bool?
    ) async throws -> TranscriptionResult? {
        guard let pipe = whisperKit else { return nil }
        let results = try await pipe.transcribe(
            audioPath: audioPath,
            decodeOptions: DecodingOptions(usePrefillPrompt: false, detectLanguage: true, wordTimestamps: true),
            callback: { progress in callback(progress) }
        )
        return results.first
    }
}
