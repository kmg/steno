import Foundation
import FluidAudio
import os

/// Layer 2 speaker diarization using FluidAudio's LS-EEND model.
/// Runs on Neural Engine. Used for in-person meetings or multi-speaker calls.
final class MLDiarizer: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "MLDiarizer")
    private var diarizer: LSEENDDiarizer?
    private(set) var isInitialized = false

    /// Initialize the diarization model. Downloads on first use.
    func initialize() async throws {
        let d = LSEENDDiarizer()
        try await d.initialize(variant: .dihard3)
        self.diarizer = d
        self.isInitialized = true
        logger.info("FluidAudio LS-EEND diarizer initialized")
    }

    /// Diarize an audio file. Returns speaker labels aligned to transcript segments.
    /// - Parameters:
    ///   - audioFileURL: Path to the .m4a audio file
    ///   - transcriptSegments: Segments to assign speakers to (by time overlap)
    /// - Returns: (speakerLabels per segment, speaker dictionary)
    func diarize(
        audioFileURL: URL,
        transcriptSegments: [(start: Float, end: Float)]
    ) throws -> (labels: [String], speakers: [String: Speaker]) {
        guard let diarizer else {
            throw DiarizationError.notInitialized
        }

        logger.info("Running ML diarization on \(audioFileURL.lastPathComponent)")

        let timeline = try diarizer.processComplete(audioFileURL: audioFileURL)

        // Collect all finalized segments from all speakers
        var diarSegments: [(start: Float, end: Float, speakerIndex: Int)] = []
        for (speakerIdx, speaker) in timeline.speakers {
            for seg in speaker.finalizedSegments {
                diarSegments.append((start: seg.startTime, end: seg.endTime, speakerIndex: speakerIdx))
            }
        }

        // Sort by start time
        diarSegments.sort { $0.start < $1.start }

        // Build speaker dictionary
        var speakers: [String: Speaker] = [:]
        let uniqueSpeakers = Set(diarSegments.map(\.speakerIndex)).sorted()
        for idx in uniqueSpeakers {
            let id = "SPEAKER_\(idx)"
            speakers[id] = Speaker(id: id, source: .mlDiarization, label: "Speaker \(idx + 1)")
        }

        // Assign speakers to transcript segments by maximum time overlap
        let labels: [String] = transcriptSegments.map { tSeg in
            var bestSpeaker = "SPEAKER_0"
            var bestOverlap: Float = 0

            for dSeg in diarSegments {
                let overlapStart = max(tSeg.start, dSeg.start)
                let overlapEnd = min(tSeg.end, dSeg.end)
                let overlap = max(0, overlapEnd - overlapStart)

                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = "SPEAKER_\(dSeg.speakerIndex)"
                }
            }

            return bestSpeaker
        }

        logger.info("ML diarization complete: \(uniqueSpeakers.count) speakers, \(diarSegments.count) segments")
        return (labels: labels, speakers: speakers)
    }

    enum DiarizationError: LocalizedError {
        case notInitialized

        var errorDescription: String? {
            "ML diarizer not initialized. Call initialize() first."
        }
    }
}
