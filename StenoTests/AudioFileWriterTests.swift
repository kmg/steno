import XCTest
import AVFoundation
@testable import Steno

/// Tests for AudioFileWriter instrumentation. Covers the failure mode from
/// the 2026-05-30 09:06 incident: writer running, zero frames written,
/// silent until AAC conversion fails downstream. The counters + heartbeat
/// + finish-with-zero-frames error make that class of failure visible.
final class AudioFileWriterTests: XCTestCase {
    var tempDir: URL!
    var writer: AudioFileWriter!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioFileWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        writer = AudioFileWriter()
    }

    override func tearDown() async throws {
        if writer.isWriting {
            writer.finish()
        }
        writer = nil
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func test_start_setsIsWriting() throws {
        XCTAssertFalse(writer.isWriting)
        let url = tempDir.appendingPathComponent("audio.wav")
        let format = makeFormat(sampleRate: 48000)
        try writer.start(outputURL: url, sourceFormat: format)
        XCTAssertTrue(writer.isWriting)
    }

    func test_appendMatchingBuffer_incrementsFrameCount() throws {
        let url = tempDir.appendingPathComponent("audio.wav")
        let format = makeFormat(sampleRate: 48000)
        try writer.start(outputURL: url, sourceFormat: format)

        let buffer = makeBuffer(format: format, frameCount: 1024)
        writer.append(buffer: buffer)

        XCTAssertEqual(writer.counters.framesWritten, 1024)
        XCTAssertEqual(writer.counters.buffersDropped, 0)
    }

    func test_appendMismatchedBuffer_incrementsDropCount() throws {
        let url = tempDir.appendingPathComponent("audio.wav")
        let writerFormat = makeFormat(sampleRate: 48000)
        try writer.start(outputURL: url, sourceFormat: writerFormat)

        // Buffer at a different sample rate — should be dropped, not written
        let bufferFormat = makeFormat(sampleRate: 16000)
        let buffer = makeBuffer(format: bufferFormat, frameCount: 1024)
        writer.append(buffer: buffer)

        XCTAssertEqual(writer.counters.framesWritten, 0)
        XCTAssertEqual(writer.counters.buffersDropped, 1)
    }

    func test_allBuffersDropped_morningIncidentScenario() throws {
        // The 2026-05-30 09:06 case: writer started at one format, every
        // buffer arrives at a different format → all dropped → empty WAV.
        // Counters should make this loud.
        let url = tempDir.appendingPathComponent("audio.wav")
        let writerFormat = makeFormat(sampleRate: 48000)
        try writer.start(outputURL: url, sourceFormat: writerFormat)

        let bufferFormat = makeFormat(sampleRate: 16000)
        for _ in 0..<100 {
            writer.append(buffer: makeBuffer(format: bufferFormat, frameCount: 1024))
        }

        XCTAssertEqual(writer.counters.framesWritten, 0)
        XCTAssertEqual(writer.counters.buffersDropped, 100)
    }

    func test_finish_resetsState() throws {
        let url = tempDir.appendingPathComponent("audio.wav")
        let format = makeFormat(sampleRate: 48000)
        try writer.start(outputURL: url, sourceFormat: format)
        writer.append(buffer: makeBuffer(format: format, frameCount: 1024))

        writer.finish()

        XCTAssertFalse(writer.isWriting)
    }

    func test_startAfterFinish_resetsCounters() throws {
        let url1 = tempDir.appendingPathComponent("audio.wav")
        let format = makeFormat(sampleRate: 48000)
        try writer.start(outputURL: url1, sourceFormat: format)
        writer.append(buffer: makeBuffer(format: format, frameCount: 2048))
        XCTAssertEqual(writer.counters.framesWritten, 2048)
        writer.finish()

        // Second session — counters should reset to 0
        let url2 = tempDir.appendingPathComponent("audio2.wav")
        try writer.start(outputURL: url2, sourceFormat: format)
        XCTAssertEqual(writer.counters.framesWritten, 0)
        XCTAssertEqual(writer.counters.buffersDropped, 0)
    }

    func test_appendWithoutStart_isNoop() {
        let format = makeFormat(sampleRate: 48000)
        writer.append(buffer: makeBuffer(format: format, frameCount: 1024))
        XCTAssertEqual(writer.counters.framesWritten, 0)
    }

    // MARK: - Helpers

    private func makeFormat(sampleRate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: sampleRate,
                      channels: 1,
                      interleaved: false)!
    }

    private func makeBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        return buffer
    }
}
