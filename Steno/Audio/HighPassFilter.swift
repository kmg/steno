import Accelerate

/// 80Hz high-pass filter using vDSP biquad.
/// Removes low-frequency rumble from audio.
struct HighPassFilter {
    private var coefficients: [Double] = []
    private var delays: [Double] = []

    init(cutoffHz: Double = 80.0, sampleRate: Double = 48000.0) {
        // Compute biquad coefficients for a 2nd-order Butterworth high-pass
        let w0 = 2.0 * Double.pi * cutoffHz / sampleRate
        let alpha = sin(w0) / (2.0 * sqrt(2.0)) // Q = sqrt(2)/2 for Butterworth

        let b0 = (1.0 + cos(w0)) / 2.0
        let b1 = -(1.0 + cos(w0))
        let b2 = (1.0 + cos(w0)) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cos(w0)
        let a2 = 1.0 - alpha

        // Normalize by a0
        coefficients = [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0]
        delays = [Double](repeating: 0, count: 4) // 2 sections * 2 delays
    }

    /// Apply high-pass filter to audio samples in-place.
    mutating func apply(to samples: inout [Float]) {
        guard !samples.isEmpty, coefficients.count == 5 else { return }

        let count = vDSP_Length(samples.count)
        var doubleSamples = samples.map { Double($0) }
        var output = [Double](repeating: 0, count: samples.count)

        vDSP_deq22D(&doubleSamples, 1, &coefficients, &output, 1, count - 2)

        samples = output.map { Float($0) }
    }
}
