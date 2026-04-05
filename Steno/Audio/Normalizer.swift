import Accelerate

/// RMS normalization for consistent volume levels.
struct Normalizer {
    let targetRMS: Float = 0.1  // target RMS level

    /// Normalize audio samples to a target RMS level.
    func apply(to samples: inout [Float]) {
        guard !samples.isEmpty else { return }

        var currentRMS: Float = 0
        vDSP_rmsqv(samples, 1, &currentRMS, vDSP_Length(samples.count))

        guard currentRMS > 0.0001 else { return } // skip near-silence

        var gain = targetRMS / currentRMS
        // Limit gain to prevent amplifying noise
        gain = min(gain, 10.0)

        vDSP_vsmul(samples, 1, &gain, &samples, 1, vDSP_Length(samples.count))

        // Clip to [-1, 1]
        var lo: Float = -1.0
        var hi: Float = 1.0
        vDSP_vclip(samples, 1, &lo, &hi, &samples, 1, vDSP_Length(samples.count))
    }
}
