import Foundation
import WhisperKit
import os

@MainActor
final class TranscriptionEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case loading(String)
        case transcribing(Float)
        case streaming
        case complete
        case error(String)
    }

    @Published var state: State = .idle
    @Published var lastTranscript: Transcript?
    @Published var liveConfirmedSegments: [TranscriptionSegment] = []
    @Published var liveUnconfirmedSegments: [TranscriptionSegment] = []

    private let worker = TranscriptionWorker()
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "TranscriptionEngine")

    var modelName: String = "tiny"
    var customModelFolder: String?

    func loadModel() async {
        state = .loading(modelName)
        logger.info("Loading WhisperKit model: \(self.modelName)")

        do {
            try await worker.load(model: modelName, modelFolder: customModelFolder)
            state = .idle
            logger.info("WhisperKit model loaded: \(self.modelName)")
        } catch {
            state = .error("Failed to load model: \(error.localizedDescription)")
            logger.error("Failed to load WhisperKit: \(error)")
        }
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
    func transcribe(audioPath: String, duration: Double) async -> Transcript? {
        state = .transcribing(0)
        logger.info("Transcribing: \(audioPath)")

        do {
            let result = try await worker.transcribe(audioPath: audioPath)

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
            state = .complete
            logger.info("Transcription complete: \(result.segments.count) segments")
            return transcript

        } catch {
            state = .error("Transcription failed: \(error.localizedDescription)")
            logger.error("Transcription failed: \(error)")
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

    func transcribe(audioPath: String) async throws -> TranscriptionResult? {
        guard let pipe = whisperKit else { return nil }
        return try await pipe.transcribe(
            audioPath: audioPath,
            decodeOptions: DecodingOptions(wordTimestamps: true)
        )
    }
}
