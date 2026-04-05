import Foundation
import os

/// Orchestrates speaker diarization.
/// Layer 1: Stream-based (Local/Remote) — free, always on when system audio is captured.
/// Layer 2: FluidAudio ML — for in-person meetings or when no system audio.
@MainActor
final class DiarizationManager: ObservableObject {
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "DiarizationManager")

    let streamDiarizer = StreamDiarizer()
    let mlDiarizer = MLDiarizer()

    @Published var mlReady = false

    /// Whether system audio is being captured (enables Layer 1).
    var systemAudioActive = false

    /// Initialize ML diarizer in background.
    func loadMLModel() async {
        do {
            try await mlDiarizer.initialize()
            mlReady = true
            logger.info("ML diarizer ready")
        } catch {
            logger.error("Failed to load ML diarizer: \(error)")
        }
    }

    /// Apply speaker labels to transcript segments.
    /// Layer 1 (stream-based) when system audio is active.
    /// Layer 2 (ML) when system audio is not active and ML model is ready.
    func applySpeakerLabels(to transcript: inout Transcript, audioFileURL: URL?) {
        if systemAudioActive {
            applyStreamLabels(to: &transcript)
        } else if mlReady, let audioURL = audioFileURL {
            applyMLLabels(to: &transcript, audioFileURL: audioURL)
        }
    }

    /// Layer 1: RMS-based Local/Remote attribution.
    private func applyStreamLabels(to transcript: inout Transcript) {
        let speakerIDs = streamDiarizer.attributeAll(
            segments: transcript.segments.map { (start: $0.start, end: $0.end) }
        )

        for i in transcript.segments.indices {
            transcript.segments[i].speaker = i < speakerIDs.count ? speakerIDs[i] : nil
        }

        transcript.speakers = [
            Speaker.local.id: Speaker.local,
            Speaker.remote.id: Speaker.remote
        ]

        let count = transcript.segments.count
        logger.info("Layer 1: stream-based labels applied to \(count) segments")
    }

    /// Layer 2: FluidAudio ML diarization.
    private func applyMLLabels(to transcript: inout Transcript, audioFileURL: URL) {
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
            logger.info("Layer 2: ML labels applied to \(count) segments")
        } catch {
            logger.error("ML diarization failed: \(error)")
        }
    }

    func reset() {
        streamDiarizer.reset()
        systemAudioActive = false
    }
}
