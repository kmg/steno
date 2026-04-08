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
}
