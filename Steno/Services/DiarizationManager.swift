import Foundation
import os

/// Speaker identification using FluidAudio ML.
/// Runs on Neural Engine. Supports up to 10 speakers, detected automatically.
@MainActor
final class DiarizationManager: ObservableObject {
    nonisolated private let log = StenoLog.diarization

    nonisolated let mlDiarizer = MLDiarizer()

    @Published var mlReady = false

    func loadMLModel() async {
        do {
            try await mlDiarizer.initialize()
            mlReady = true
            log.info("Speaker identification ready")
        } catch {
            log.error("Failed to load speaker identification model: \(error)")
        }
    }

    /// Returns a new transcript with speaker labels applied via FluidAudio ML.
    ///
    /// CoreML inference takes seconds and MUST run off the main thread.
    /// Always call this from `Task.detached { ... }`, never from a main-actor
    /// `Task { ... }` (which inherits MainActor isolation and would hang the UI).
    nonisolated func applyingSpeakerLabels(to transcript: Transcript, audioFileURL: URL) -> Transcript {
        guard mlDiarizer.isInitialized else {
            log.info("Speaker identification not ready, skipping")
            return transcript
        }

        do {
            let segments = transcript.segments.map { (start: $0.start, end: $0.end) }
            let result = try mlDiarizer.diarize(
                audioFileURL: audioFileURL,
                transcriptSegments: segments
            )

            var updated = transcript
            for i in updated.segments.indices {
                updated.segments[i].speaker = i < result.labels.count ? result.labels[i] : nil
            }
            updated.speakers = result.speakers

            let count = updated.segments.count
            let speakerCount = result.speakers.count
            log.info("Speaker identification complete: \(speakerCount) speakers, \(count) segments")
            return updated
        } catch {
            log.error("Speaker identification failed: \(error)")
            return transcript
        }
    }
}
