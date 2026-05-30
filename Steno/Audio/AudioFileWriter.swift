import AVFoundation
import os

/// Writes microphone PCM buffers to a WAV (LPCM) file.
/// Uses AVAudioFile for reliable buffer-to-file writing.
/// WAV accepts any format/sample rate — no bitrate negotiation, no encoder errors.
/// Post-recording conversion to AAC is handled by AudioConverter.
///
/// Instrumentation (see ADR-0011): tracks frames-written and buffers-dropped
/// counters, emits a heartbeat log every ~10s of audio, and on finish()
/// reports the totals. This makes silent-drop failure modes visible in the
/// Debug tab — the 2026-05-30 09:06 incident produced an empty WAV with no
/// log signal during the recording; the instrumentation here surfaces that
/// class of failure as it happens, not after a failed AAC conversion.
///
/// Thread safety: `append` is called from the audio IO thread,
/// `start`/`finish` from the main thread. Lock protects all mutable state.
final class AudioFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private let log = StenoLog.audio
    private var _isWriting = false

    // Instrumentation counters — all guarded by `lock`.
    private var framesWritten: AVAudioFramePosition = 0
    private var buffersDropped: Int = 0
    private var lastHeartbeatFrames: AVAudioFramePosition = 0
    private var lastDropLogAt: Date?

    /// Heartbeat fires every ~10s of writable audio (480k frames at 48kHz,
    /// 160k at 16kHz). Real interval depends on the file's sample rate.
    private let heartbeatFrameInterval: AVAudioFramePosition = 480_000

    /// Drop-counter warnings are throttled to once every this many seconds
    /// so the audio thread doesn't flood the log when every buffer is dropped.
    private let dropLogThrottleSeconds: TimeInterval = 5.0

    var isWriting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isWriting
    }

    /// Snapshot of the live counters — for tests and for the Debug tab to
    /// surface "X frames, Y drops" without unlocking the audio thread.
    var counters: (framesWritten: AVAudioFramePosition, buffersDropped: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (framesWritten, buffersDropped)
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
        framesWritten = 0
        buffersDropped = 0
        lastHeartbeatFrames = 0
        lastDropLogAt = nil
        lock.unlock()

        log.info("Audio writer started: \(outputURL.lastPathComponent), format: \(sourceFormat.sampleRate)Hz \(sourceFormat.channelCount)ch")
    }

    /// Append a PCM buffer. Call from the audio tap callback.
    /// Validates that the buffer's sample rate matches the file's processing format.
    /// Mismatched buffers (e.g. from a failed format conversion after device change)
    /// are dropped with a throttled warning rather than corrupting the recording.
    /// Successful writes increment a frame counter; every ~10s of audio a
    /// heartbeat log fires so silent failure modes (all-buffers-dropped) are
    /// visible in real time rather than only after AAC conversion fails.
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
            buffersDropped += 1
            let now = Date()
            let shouldLog = lastDropLogAt.map { now.timeIntervalSince($0) >= dropLogThrottleSeconds } ?? true
            if shouldLog {
                log.warning("Buffer dropped: file \(fileSR)Hz, buffer \(bufferSR)Hz — \(buffersDropped) total drops")
                lastDropLogAt = now
            }
            lock.unlock()
            return
        }

        do {
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)

            // Heartbeat: emit info-level log every ~10s of audio so the Debug
            // tab shows steady progress during a recording. Silent failure
            // (all-drop) shows up as "framesWritten stops increasing."
            if framesWritten - lastHeartbeatFrames >= heartbeatFrameInterval {
                let seconds = Double(framesWritten) / fileSR
                log.info("Writer heartbeat: \(String(format: "%.1f", seconds))s, \(framesWritten) frames, \(buffersDropped) drops")
                lastHeartbeatFrames = framesWritten
            }
        } catch {
            log.error("Failed to write audio buffer: \(error)")
        }
        lock.unlock()
    }

    /// Finish writing. Emits a final report with frames, drops, and duration.
    /// An empty WAV (framesWritten == 0) is logged as an error so the Debug
    /// tab clearly surfaces failed-recording sessions before AAC conversion
    /// fails with the less-informative "cannot complete" downstream error.
    func finish() {
        lock.lock()
        guard _isWriting else {
            lock.unlock()
            return
        }
        let frames = framesWritten
        let drops = buffersDropped
        let sampleRate = audioFile?.processingFormat.sampleRate ?? 1
        audioFile = nil
        _isWriting = false
        lock.unlock()

        let seconds = Double(frames) / sampleRate
        if frames == 0 {
            log.error("Audio writer finished with 0 frames written (\(drops) buffers dropped) — recording appears empty")
        } else {
            log.info("Audio writer finished: \(String(format: "%.1f", seconds))s (\(frames) frames), \(drops) drops")
        }
    }

}
