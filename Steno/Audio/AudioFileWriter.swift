import AVFoundation
import os

/// Writes microphone PCM buffers to a WAV (LPCM) file.
/// Uses AVAudioFile for reliable buffer-to-file writing.
/// WAV accepts any format/sample rate — no bitrate negotiation, no encoder errors.
/// Post-recording conversion to AAC is handled by AudioConverter.
///
/// Thread safety: `append` is called from the audio IO thread,
/// `start`/`finish` from the main thread. Lock protects `audioFile`.
final class AudioFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private let log = StenoLog.audio
    private var _isWriting = false

    var isWriting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isWriting
    }

    /// Start writing audio to the given file URL as WAV (LPCM).
    /// LPCM accepts any sample rate and channel count — no encoder configuration needed.
    func start(outputURL: URL, sourceFormat: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sourceFormat.sampleRate,
            AVNumberOfChannelsKey: min(Int(sourceFormat.channelCount), 2),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: settings,
            commonFormat: sourceFormat.commonFormat,
            interleaved: sourceFormat.isInterleaved
        )

        lock.lock()
        audioFile = file
        _isWriting = true
        lock.unlock()

        log.info("Audio writer started: \(outputURL.lastPathComponent), format: \(sourceFormat.sampleRate)Hz \(sourceFormat.channelCount)ch")
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
                log.error("Buffer sample rate (\(bufferSR)) != file sample rate (\(fileSR)), dropping buffer")
                _formatMismatchLogged = true
            }
            lock.unlock()
            return
        }

        do {
            try file.write(from: buffer)
        } catch {
            log.error("Failed to write audio buffer: \(error)")
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
        log.info("Audio writer finished")
    }

}
