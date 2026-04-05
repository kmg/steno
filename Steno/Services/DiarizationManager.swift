import Foundation
import os

/// Speaker identification using FluidAudio ML.
/// Runs on Neural Engine. Supports up to 10 speakers, detected automatically.
@MainActor
final class DiarizationManager: ObservableObject {
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "DiarizationManager")

    let mlDiarizer = MLDiarizer()

    @Published var mlReady = false

    func loadMLModel() async {
        do {
            try await mlDiarizer.initialize()
            mlReady = true
            logger.info("Speaker identification ready")
        } catch {
            logger.error("Failed to load speaker identification model: \(error)")
        }
    }

    /// Apply speaker labels to transcript segments using FluidAudio ML.
    func applySpeakerLabels(to transcript: inout Transcript, audioFileURL: URL) {
        guard mlReady else {
            logger.info("Speaker identification not ready, skipping")
            return
        }

        do {
            let segments = transcript.segments.map { (start: $0.start, end: $0.end) }
            let result = try mlDiarizer.diarize(
                audioFileURL: audioFileURL,
                transcriptSegments: segments
            )

            for i in transcript.segments.indices {
                transcript.segments[i].speaker = i < result.labels.count ? result.labels[i] : nil
            }

            transcript.speakers = result.speakers
            let count = transcript.segments.count
            let speakerCount = result.speakers.count
            logger.info("Speaker identification complete: \(speakerCount) speakers, \(count) segments")
        } catch {
            logger.error("Speaker identification failed: \(error)")
        }
    }
}
