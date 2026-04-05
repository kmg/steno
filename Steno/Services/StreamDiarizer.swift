import Foundation
import Accelerate
import os

/// Layer 1 speaker attribution: labels segments as Local (mic) or Remote (system audio)
/// based on which audio stream had higher RMS energy at each segment's timestamp.
///
/// Logic: When the remote person speaks, system audio has strong signal AND mic has
/// relatively low signal (just acoustic bleed). When the local person speaks, mic has
/// strong signal regardless of system audio level.
final class StreamDiarizer {
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "StreamDiarizer")

    struct EnergySnapshot {
        let timestamp: TimeInterval
        let micRMS: Float
        let systemRMS: Float
    }

    private var snapshots: [EnergySnapshot] = []
    private let snapshotInterval: TimeInterval = 0.25 // capture every 250ms for finer granularity

    // Thresholds
    private let speechThreshold: Float = 0.005   // minimum RMS to count as "speech"

    /// Record energy levels from both streams.
    func recordEnergy(micSamples: [Float], systemSamples: [Float], timestamp: TimeInterval) {
        let micRMS = rms(micSamples)
        let systemRMS = rms(systemSamples)

        snapshots.append(EnergySnapshot(
            timestamp: timestamp,
            micRMS: micRMS,
            systemRMS: systemRMS
        ))
    }

    /// Attribute a speaker to a segment based on energy patterns.
    ///
    /// - Remote: system audio has strong signal, mic signal is weak (just bleed from speakers)
    /// - Local: mic has strong signal (local person talking, regardless of system audio)
    func attributeSpeaker(segmentStart: Float, segmentEnd: Float) -> String {
        let start = TimeInterval(segmentStart)
        let end = TimeInterval(segmentEnd)

        let relevant = snapshots.filter { $0.timestamp >= start - 0.5 && $0.timestamp <= end + 0.5 }
        guard !relevant.isEmpty else { return Speaker.local.id }

        let avgMicRMS = relevant.map(\.micRMS).reduce(0, +) / Float(relevant.count)
        let avgSystemRMS = relevant.map(\.systemRMS).reduce(0, +) / Float(relevant.count)

        // If mic is clearly active (local person speaking), it's local
        // even if system audio is also present
        let micActive = avgMicRMS > speechThreshold
        let systemActive = avgSystemRMS > speechThreshold

        if systemActive && (!micActive || avgSystemRMS > avgMicRMS * 2.0) {
            return Speaker.remote.id
        }
        return Speaker.local.id
    }

    func attributeAll(segments: [(start: Float, end: Float)]) -> [String] {
        return segments.map { attributeSpeaker(segmentStart: $0.start, segmentEnd: $0.end) }
    }

    func reset() {
        snapshots = []
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_rmsqv(samples, 1, &result, vDSP_Length(samples.count))
        return result
    }
}
