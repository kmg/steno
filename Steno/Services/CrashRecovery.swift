import Foundation
import os

/// On launch, scans for sessions with status "recording" — these were interrupted
/// by a crash or force-quit. Marks them as recovered.
struct CrashRecovery {
    private static let logger = Logger(subsystem: "com.kmganesh.steno", category: "CrashRecovery")

    /// Finds sessions left in "recording" status (crash/force-quit) and marks them recovered.
    /// Audio and transcript files are already on disk — this just fixes the metadata.
    static func recoverSessions(in baseURL: URL) -> [String] {
        let fileManager = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var recoveredIDs: [String] = []

        guard let contents = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil
        ) else { return [] }

        for folder in contents where folder.hasDirectoryPath {
            let metadataURL = folder.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  var session = try? decoder.decode(Session.self, from: data),
                  session.status == .recording else { continue }

            // Repair WAV header if recording was interrupted — AVAudioFile
            // writes size fields on close, so a crash leaves them at initial values.
            let wavURL = folder.appendingPathComponent("audio.wav")
            if fileManager.fileExists(atPath: wavURL.path) {
                repairWAVHeader(at: wavURL)
                // Convert recovered WAV to AAC in background
                Task.detached {
                    await AudioConverter.convertToAAC(wavURL: wavURL)
                }
            }

            session.status = .recovered
            session.endedAt = session.endedAt ?? Date()

            if let encoded = try? encoder.encode(session) {
                try? encoded.write(to: metadataURL, options: .atomic)
            }

            recoveredIDs.append(session.id)
            Analytics.sessionRecovered(sessionID: session.id)
            logger.info("Session recovered: \(session.id)")
        }

        return recoveredIDs
    }

    /// Repair WAV/RIFF header after a crash.
    /// AVAudioFile writes size fields (bytes 4-7 and 40-43) on close.
    /// A crash leaves them at initial values. Fix: compute from actual file size.
    private static func repairWAVHeader(at url: URL) {
        guard let fh = try? FileHandle(forUpdating: url) else { return }
        defer { try? fh.close() }

        let fileSize = fh.seekToEndOfFile()
        guard fileSize > 44 else { return }

        // Verify RIFF magic bytes
        fh.seek(toFileOffset: 0)
        guard let magic = try? fh.read(upToCount: 4),
              magic == Data([0x52, 0x49, 0x46, 0x46]) else { return }

        var riffSize = UInt32(fileSize - 8).littleEndian
        var dataSize = UInt32(fileSize - 44).littleEndian

        // Patch RIFF chunk size (bytes 4-7)
        fh.seek(toFileOffset: 4)
        fh.write(Data(bytes: &riffSize, count: 4))

        // Patch data subchunk size (bytes 40-43)
        fh.seek(toFileOffset: 40)
        fh.write(Data(bytes: &dataSize, count: 4))

        logger.info("Repaired WAV header: \(url.lastPathComponent) (\(fileSize) bytes)")
    }
}
