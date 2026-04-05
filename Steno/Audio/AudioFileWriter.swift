import AVFoundation
import os

/// Writes microphone PCM buffers to an AAC .m4a file.
/// Uses AVAudioFile for reliable buffer-to-file writing.
final class AudioFileWriter: @unchecked Sendable {
    private var audioFile: AVAudioFile?
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "AudioFileWriter")
    private(set) var isWriting = false

    /// Start writing audio to the given file URL.
    func start(outputURL: URL, sourceFormat: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sourceFormat.sampleRate,
            AVNumberOfChannelsKey: min(Int(sourceFormat.channelCount), 2),
            AVEncoderBitRateKey: 128_000
        ]

        audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: settings,
            commonFormat: sourceFormat.commonFormat,
            interleaved: sourceFormat.isInterleaved
        )

        isWriting = true
        logger.info("Audio writer started: \(outputURL.lastPathComponent), format: \(sourceFormat.sampleRate)Hz \(sourceFormat.channelCount)ch")
    }

    /// Append a PCM buffer. Call from the audio tap callback.
    func append(buffer: AVAudioPCMBuffer) {
        guard isWriting, let file = audioFile else { return }
        guard buffer.frameLength > 0 else { return }

        do {
            try file.write(from: buffer)
        } catch {
            logger.error("Failed to write audio buffer: \(error)")
        }
    }

    /// Finish writing.
    func finish() {
        guard isWriting else { return }
        audioFile = nil // closing the file finalizes it
        isWriting = false
        logger.info("Audio writer finished")
    }

    enum WriterError: LocalizedError {
        case cannotAddInput
        case startFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .cannotAddInput:
                return "Cannot add audio input to writer"
            case .startFailed(let error):
                return "Writer failed to start: \(error?.localizedDescription ?? "unknown")"
            }
        }
    }
}
