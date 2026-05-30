import XCTest
import AVFoundation
@testable import Steno

/// Tests for AudioConverter — the WAV→AAC post-recording converter.
/// This file's bug class is what broke v0.2.17 (macOS availability mismatch
/// on `AVAssetExportSession.export(to:as:)`). These tests exercise the real
/// AVFoundation export path with synthetic WAV input.
final class AudioConverterTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioConverterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func test_singleSegment_producesM4A() async throws {
        let wavURL = tempDir.appendingPathComponent("audio.wav")
        try writeSilentWAV(at: wavURL, duration: 1.0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavURL.path), "fixture WAV should exist before conversion")

        await AudioConverter.convertToAAC(wavURL: wavURL)

        let m4aURL = tempDir.appendingPathComponent("audio.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: m4aURL.path),
                      "converter should produce audio.m4a from a valid WAV input")

        let asset = AVURLAsset(url: m4aURL)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.5,
                             "converted file should have non-trivial duration (input was ~1s)")
    }

    func test_multipleSegments_concatenated() async throws {
        let wavURL = tempDir.appendingPathComponent("audio.wav")
        let seg1URL = tempDir.appendingPathComponent("audio-seg1.wav")
        let seg2URL = tempDir.appendingPathComponent("audio-seg2.wav")
        try writeSilentWAV(at: wavURL, duration: 1.0)
        try writeSilentWAV(at: seg1URL, duration: 1.0)
        try writeSilentWAV(at: seg2URL, duration: 1.0)

        await AudioConverter.convertToAAC(wavURL: wavURL)

        let m4aURL = tempDir.appendingPathComponent("audio.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: m4aURL.path),
                      "converter should produce audio.m4a from multi-segment WAV input")

        let asset = AVURLAsset(url: m4aURL)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 2.5,
                             "3 segments × 1s should concatenate to >2.5s (allow encoder overhead)")
    }

    func test_segmentDiscoveryStopsAtFirstGap() async throws {
        // audio.wav + audio-seg1.wav exists, audio-seg2.wav is missing
        // → converter should include the first two and stop
        let wavURL = tempDir.appendingPathComponent("audio.wav")
        let seg1URL = tempDir.appendingPathComponent("audio-seg1.wav")
        let seg3URL = tempDir.appendingPathComponent("audio-seg3.wav")
        try writeSilentWAV(at: wavURL, duration: 1.0)
        try writeSilentWAV(at: seg1URL, duration: 1.0)
        try writeSilentWAV(at: seg3URL, duration: 1.0)  // gap at seg2

        await AudioConverter.convertToAAC(wavURL: wavURL)

        let m4aURL = tempDir.appendingPathComponent("audio.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: m4aURL.path),
                      "converter should still produce audio.m4a even with discontinuous segment numbering")

        let asset = AVURLAsset(url: m4aURL)
        let duration = try await asset.load(.duration)
        // Should include audio.wav + seg1 only (~2s) — NOT seg3 since seg2 was missing
        XCTAssertLessThan(duration.seconds, 2.5,
                          "seg3 should be ignored because seg2 was missing — segment discovery stops at first gap")
    }

    func test_missingInput_doesNotCrash() async {
        let wavURL = tempDir.appendingPathComponent("nonexistent.wav")

        // Must not crash — graceful failure expected
        await AudioConverter.convertToAAC(wavURL: wavURL)

        let m4aURL = tempDir.appendingPathComponent("audio.m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: m4aURL.path),
                       "no input → no output")
    }

    func test_atomicWrite_noPartialFileOnSuccess() async throws {
        // The converter writes to audio-converting.m4a, verifies, then renames to audio.m4a.
        // After a successful conversion, the .tmp file should not exist.
        let wavURL = tempDir.appendingPathComponent("audio.wav")
        try writeSilentWAV(at: wavURL, duration: 1.0)

        await AudioConverter.convertToAAC(wavURL: wavURL)

        let tmpURL = tempDir.appendingPathComponent("audio-converting.m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path),
                       "temp .m4a should not exist after successful conversion (atomic rename)")
    }

    // MARK: - Helpers

    /// Writes a `duration`-second silent mono WAV at `url`, 48kHz LPCM.
    /// Uses AVAudioFile which writes WAV/LPCM when the file extension is .wav.
    private func writeSilentWAV(at url: URL, duration: TimeInterval, sampleRate: Double = 48000) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false) else {
            throw NSError(domain: "AudioConverterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to create AVAudioFormat"])
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "AudioConverterTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "failed to allocate PCM buffer"])
        }
        buffer.frameLength = frameCount
        // Buffer is zero-initialized — silent audio.

        try file.write(from: buffer)
    }
}
