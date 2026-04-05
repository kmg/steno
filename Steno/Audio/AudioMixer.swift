import AVFoundation
import Accelerate
import os

/// Mixes microphone and system audio streams.
/// Applies RMS-based ducking: reduces system audio when mic detects speech.
final class AudioMixer {
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "AudioMixer")

    private let duckingThreshold: Float = 0.01  // RMS level above which mic is "active"
    private let duckingAmount: Float = 0.3       // Multiply system audio by this when ducking

    /// Mix system audio buffer list into a PCM buffer compatible with our pipeline.
    /// Returns mono Float samples at the system audio's sample rate.
    func samplesFromBufferList(_ bufferList: UnsafePointer<AudioBufferList>) -> [Float]? {
        let abl = bufferList.pointee
        guard abl.mNumberBuffers > 0 else { return nil }

        let buffer = abl.mBuffers
        guard buffer.mDataByteSize > 0, let data = buffer.mData else { return nil }

        let floatCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard floatCount > 0 else { return nil }

        let floatPtr = data.bindMemory(to: Float.self, capacity: floatCount)
        let channels = Int(buffer.mNumberChannels)

        if channels <= 1 {
            return Array(UnsafeBufferPointer(start: floatPtr, count: floatCount))
        }

        // Deinterleave stereo to mono by averaging channels
        let frameCount = floatCount / channels
        var mono = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            var sum: Float = 0
            for ch in 0..<channels {
                sum += floatPtr[i * channels + ch]
            }
            mono[i] = sum / Float(channels)
        }
        return mono
    }

    /// Compute RMS energy of a float buffer.
    func rmsEnergy(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }

    /// Mix mic and system samples with ducking.
    /// Both inputs should be mono at the same sample rate.
    /// Returns mixed mono samples.
    func mix(micSamples: [Float], systemSamples: [Float]) -> [Float] {
        let count = min(micSamples.count, systemSamples.count)
        guard count > 0 else { return micSamples.isEmpty ? systemSamples : micSamples }

        let micRMS = rmsEnergy(Array(micSamples.prefix(count)))
        let ducking: Float = micRMS > duckingThreshold ? duckingAmount : 1.0

        var mixed = [Float](repeating: 0, count: count)
        var scaledSystem = [Float](repeating: 0, count: count)

        // Scale system audio by ducking factor
        var duckFactor = ducking
        vDSP_vsmul(systemSamples, 1, &duckFactor, &scaledSystem, 1, vDSP_Length(count))

        // Add mic + ducked system
        vDSP_vadd(micSamples, 1, scaledSystem, 1, &mixed, 1, vDSP_Length(count))

        // Clip prevention: soft clamp to [-1, 1]
        var lo: Float = -1.0
        var hi: Float = 1.0
        vDSP_vclip(mixed, 1, &lo, &hi, &mixed, 1, vDSP_Length(count))

        return mixed
    }
}
