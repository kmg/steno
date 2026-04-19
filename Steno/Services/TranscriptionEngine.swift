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
            // WhisperKit/HuggingFace Hub: model not cached and no internet to download.
            // User environment issue, not an app bug — show actionable message, don't pollute telemetry.
            // Multiple error surfaces emit this:
            //   - Hub.HubApi.EnvironmentError.offlineModeError (repo not available locally)
            //   - WhisperKit.WhisperError.modelsUnavailable (wraps NSURLError)
            //   - NSURLErrorDomain code -1009 (not connected to internet) during download
            if Self.isOfflineModelError(error) {
                state = .error("Model \(modelName) not downloaded. Connect to the internet for first-time setup.")
                logger.info("Model load deferred — offline and not cached: \(self.modelName)")
            } else {
                state = .error("Failed to load model: \(error.localizedDescription)")
                logger.error("Failed to load WhisperKit: \(error)")
                Analytics.captureError(error, context: ["action": "load_model", "model": modelName])
            }
        }
    }

    /// Detect "network unreachable + model not cached" — surfaces through multiple WhisperKit/Hub paths.
    private static func isOfflineModelError(_ error: Error) -> Bool {
        let nsError = error as NSError
        // NSURLErrorDomain: -1009 not connected, -1020 no internet, -1200 offline
        if nsError.domain == NSURLErrorDomain {
            return true
        }
        // Walk underlying errors for NSURL network codes
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain {
            return true
        }
        // String-match fallback for WhisperKit/Hub error types that wrap the network error
        let description = String(describing: error)
        let patterns = [
            "offlineModeError",
            "Repository not available locally",
            "modelsUnavailable",
            "Internet connection appears to be offline",
            "No network route"
        ]
        return patterns.contains { description.contains($0) }
    }

    /// WhisperKit models cache at ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/
    /// via swift-transformers HubApi (downloadBase defaults to ~/Documents/huggingface/).
    /// The model subdirectory is named openai_whisper-{model} (e.g. openai_whisper-large-v3_turbo).
    private func isModelCached(_ model: String) -> Bool {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let modelDir = documents
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
        let whisperModel = "openai_whisper-\(model)"
        return FileManager.default.fileExists(
            atPath: modelDir.appendingPathComponent(whisperModel).path
        )
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
