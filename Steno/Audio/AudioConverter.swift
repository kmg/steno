import AVFoundation
import os

/// Converts WAV (LPCM) recordings to AAC .m4a after recording completes.
/// Deletes the WAV only after verified conversion. If conversion fails,
/// the WAV remains as fallback — the user never loses audio.
enum AudioConverter {
    private static let log = StenoLog.audio

    /// Convert WAV file(s) to AAC .m4a. Trashes the WAVs on success.
    /// If multiple segments exist (from device switches mid-recording),
    /// they are concatenated via AVMutableComposition before export.
    ///
    /// Uses atomic write: exports to a temp .m4a, verifies, then renames to audio.m4a.
    /// If the app quits mid-conversion, no partial audio.m4a can exist.
    static func convertToAAC(wavURL: URL) async {
        // Check for additional segments (audio-seg1.wav, audio-seg2.wav, etc.)
        let folder = wavURL.deletingLastPathComponent()
        var allWAVs = [wavURL]
        for i in 1...20 {
            let segURL = folder.appendingPathComponent("audio-seg\(i).wav")
            if FileManager.default.fileExists(atPath: segURL.path) {
                allWAVs.append(segURL)
            } else {
                break
            }
        }

        let m4aURL = folder.appendingPathComponent("audio.m4a")
        // Temp file keeps .m4a extension so AVFoundation can read it for verification
        let tmpURL = folder.appendingPathComponent("audio-converting.m4a")

        // Clean up any leftover temp from a prior interrupted conversion
        try? FileManager.default.removeItem(at: tmpURL)

        // Build the asset: single file or composition of segments
        let exportAsset: AVAsset
        if allWAVs.count == 1 {
            exportAsset = AVURLAsset(url: wavURL)
        } else {
            // Concatenate segments via AVMutableComposition.
            // AVFoundation handles sample rate conversion between segments automatically.
            let composition = AVMutableComposition()
            var insertTime = CMTime.zero
            for segURL in allWAVs {
                let segAsset = AVURLAsset(url: segURL)
                let segDuration = try? await segAsset.load(.duration)
                guard let segDuration, segDuration.seconds > 0 else { continue }
                do {
                    try await composition.insertTimeRange(
                        CMTimeRange(start: .zero, duration: segDuration),
                        of: segAsset,
                        at: insertTime
                    )
                    insertTime = CMTimeAdd(insertTime, segDuration)
                } catch {
                    log.warning("Failed to add segment \(segURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
            log.info("Composed \(allWAVs.count) segments, total \(Int(insertTime.seconds))s")
            exportAsset = composition
        }

        guard let exportSession = AVAssetExportSession(
            asset: exportAsset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            log.error("Failed to create export session")
            return
        }

        // Export to temp file — not the final audio.m4a
        do {
            try await exportSession.export(to: tmpURL, as: .m4a)
        } catch {
            log.error("AAC conversion failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tmpURL)
            return
        }

        // Verify the output is a valid audio file with non-zero duration
        let outputAsset = AVURLAsset(url: tmpURL)
        let duration = try? await outputAsset.load(.duration)
        guard let duration, duration.seconds > 0 else {
            log.error("AAC conversion produced invalid file, keeping WAV")
            try? FileManager.default.removeItem(at: tmpURL)
            return
        }

        // Atomic rename: audio-converting.m4a → audio.m4a
        // After this, audio.m4a is guaranteed complete and valid.
        do {
            try FileManager.default.moveItem(at: tmpURL, to: m4aURL)
        } catch {
            log.error("Failed to finalize audio.m4a: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tmpURL)
            return
        }

        // Trash all WAV segments — recoverable from macOS Trash if conversion was bad
        for segURL in allWAVs {
            do {
                try FileManager.default.trashItem(at: segURL, resultingItemURL: nil)
            } catch {
                log.warning("Failed to trash \(segURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        log.info("Converted to AAC (\(Int(duration.seconds))s), trashed \(allWAVs.count) WAV file(s)")
    }
}
