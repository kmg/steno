import Foundation
import AVFoundation
import WhisperKit
import Accelerate
import os

/// Accumulates PCM audio samples and periodically transcribes them with WhisperKit.
/// Produces confirmed and unconfirmed segments for live display.
final class StreamingTranscriber: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "StreamingTranscriber")

    private var audioSamples: [Float] = []
    private var lastTranscribedCount: Int = 0
    private var isRunning = false

    private let whisperKit: WhisperKit
    private let sampleRate: Double
    private let minBufferSeconds: Float = 1.5

    /// Segments confirmed by multiple transcription passes.
    private(set) var confirmedSegments: [TranscriptionSegment] = []
    /// Segments from the most recent pass, not yet confirmed.
    private(set) var unconfirmedSegments: [TranscriptionSegment] = []

    private var lastConfirmedEnd: Float = 0
    private let requiredConfirmations = 2

    var onSegmentsUpdated: (([TranscriptionSegment], [TranscriptionSegment]) -> Void)?

    init(whisperKit: WhisperKit, sampleRate: Double) {
        self.whisperKit = whisperKit
        self.sampleRate = sampleRate
    }

    /// Append PCM samples from the microphone tap.
    /// Converts to 16kHz mono Float if needed.
    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        // Mix to mono if stereo
        var monoSamples = [Float](repeating: 0, count: frameCount)
        if channelCount == 1 {
            monoSamples = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))
        } else {
            let left = UnsafeBufferPointer(start: floatData[0], count: frameCount)
            let right = UnsafeBufferPointer(start: floatData[min(1, channelCount - 1)], count: frameCount)
            vDSP.add(left, right, result: &monoSamples)
            vDSP.divide(monoSamples, 2.0, result: &monoSamples)
        }

        // Resample to 16kHz if needed
        let sourceSR = buffer.format.sampleRate
        if abs(sourceSR - 16000) > 1 {
            let ratio = 16000.0 / sourceSR
            let outputCount = Int(Double(frameCount) * ratio)
            var resampled = [Float](repeating: 0, count: outputCount)
            // Simple linear interpolation resample
            for i in 0..<outputCount {
                let srcIdx = Double(i) / ratio
                let lo = Int(srcIdx)
                let hi = min(lo + 1, frameCount - 1)
                let frac = Float(srcIdx - Double(lo))
                resampled[i] = monoSamples[lo] * (1 - frac) + monoSamples[hi] * frac
            }
            audioSamples.append(contentsOf: resampled)
        } else {
            audioSamples.append(contentsOf: monoSamples)
        }
    }

    /// Start the transcription loop. Runs until stop() is called.
    func start() async {
        isRunning = true
        confirmedSegments = []
        unconfirmedSegments = []
        audioSamples = []
        lastTranscribedCount = 0
        lastConfirmedEnd = 0

        while isRunning {
            do {
                try await transcribeCurrentBuffer()
                try await Task.sleep(nanoseconds: 200_000_000) // 200ms between attempts
            } catch {
                if isRunning {
                    logger.error("Streaming transcription error: \(error)")
                }
                break
            }
        }
    }

    func stop() {
        isRunning = false
    }

    /// Get all segments (confirmed + unconfirmed) for final output.
    func allSegments() -> [TranscriptionSegment] {
        return confirmedSegments + unconfirmedSegments
    }

    // MARK: - Private

    private func transcribeCurrentBuffer() async throws {
        let currentCount = audioSamples.count
        let newSamples = currentCount - lastTranscribedCount
        let newSeconds = Float(newSamples) / 16000.0

        guard newSeconds >= minBufferSeconds else { return }

        lastTranscribedCount = currentCount

        let samples = Array(audioSamples)

        var options = DecodingOptions(wordTimestamps: true)
        options.clipTimestamps = [lastConfirmedEnd]

        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )

        guard let result = results.first else { return }
        let segments = result.segments

        // Confirmation logic: segments seen in multiple passes get confirmed
        if segments.count > requiredConfirmations {
            let toConfirm = Array(segments.prefix(segments.count - requiredConfirmations))
            let remaining = Array(segments.suffix(requiredConfirmations))

            if let lastConfirmed = toConfirm.last, lastConfirmed.end > lastConfirmedEnd {
                lastConfirmedEnd = lastConfirmed.end

                for seg in toConfirm {
                    if !confirmedSegments.contains(where: { $0.id == seg.id && $0.start == seg.start }) {
                        confirmedSegments.append(seg)
                    }
                }
            }

            unconfirmedSegments = remaining
        } else {
            unconfirmedSegments = segments
        }

        onSegmentsUpdated?(confirmedSegments, unconfirmedSegments)
    }
}
