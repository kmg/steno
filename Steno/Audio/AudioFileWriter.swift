import AVFoundation
import os

/// Writes microphone PCM buffers to an AAC .m4a file.
/// Uses AVAudioFile for reliable buffer-to-file writing.
///
/// Thread safety: `append` is called from the audio IO thread,
/// `start`/`finish` from the main thread. Lock protects `audioFile`.
final class AudioFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "AudioFileWriter")
    private var _isWriting = false

    var isWriting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isWriting
    }

    /// Start writing audio to the given file URL.
    /// Tries 128kbps AAC first; if the encoder rejects that bitrate for the current
    /// audio device (e.g. after switching to Bluetooth headphones), retries without
    /// an explicit bitrate and lets AVFoundation pick a supported default.
    func start(outputURL: URL, sourceFormat: AVAudioFormat) throws {
        let baseSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sourceFormat.sampleRate,
            AVNumberOfChannelsKey: min(Int(sourceFormat.channelCount), 2)
        ]

        var settings = baseSettings
        settings[AVEncoderBitRateKey] = 128_000

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: sourceFormat.commonFormat,
                interleaved: sourceFormat.isInterleaved
            )
        } catch {
            // Bitrate not supported for this device/format — retry without explicit bitrate
            logger.warning("AAC 128kbps failed (\(error.localizedDescription)), retrying with default bitrate")
            file = try AVAudioFile(
                forWriting: outputURL,
                settings: baseSettings,
                commonFormat: sourceFormat.commonFormat,
                interleaved: sourceFormat.isInterleaved
            )
        }

        lock.lock()
        audioFile = file
        _isWriting = true
        lock.unlock()

        logger.info("Audio writer started: \(outputURL.lastPathComponent), format: \(sourceFormat.sampleRate)Hz \(sourceFormat.channelCount)ch")
    }

    /// Append a PCM buffer. Call from the audio tap callback.
    /// Validates that the buffer's sample rate matches the file's processing format.
    /// Mismatched buffers (e.g. from a failed format conversion after device change)
    /// are dropped with a warning rather than corrupting the recording.
    func append(buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }

        lock.lock()
        guard _isWriting, let file = audioFile else {
            lock.unlock()
            return
        }

        // Guard against format mismatch — a device change may produce buffers at a
        // different sample rate if the mic's format converter failed or wasn't created.
        let fileSR = file.processingFormat.sampleRate
        let bufferSR = buffer.format.sampleRate
        if abs(fileSR - bufferSR) > 1 {
            if !_formatMismatchLogged {
                logger.error("Buffer sample rate (\(bufferSR)) != file sample rate (\(fileSR)), dropping buffer")
                _formatMismatchLogged = true
            }
            lock.unlock()
            return
        }

        do {
            try file.write(from: buffer)
        } catch {
            logger.error("Failed to write audio buffer: \(error)")
        }
        lock.unlock()
    }

    private var _formatMismatchLogged = false

    /// Finish writing.
    func finish() {
        lock.lock()
        guard _isWriting else {
            lock.unlock()
            return
        }
        audioFile = nil
        _isWriting = false
        lock.unlock()
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
