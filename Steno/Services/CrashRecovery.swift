import Foundation
import os

/// On launch, scans for sessions with status "recording" — these were interrupted
/// by a crash or force-quit. Marks them as recovered.
struct CrashRecovery {
    private static let logger = Logger(subsystem: "com.kmganesh.steno", category: "CrashRecovery")

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
                  var session = try? decoder.decode(Session.self, from: data) else { continue }

            if session.status == .recording {
                // This session was interrupted
                session.status = .recovered
                session.endedAt = session.endedAt ?? Date()

                // Calculate duration from audio file if possible
                let audioURL = folder.appendingPathComponent("audio.m4a")
                if fileManager.fileExists(atPath: audioURL.path) {
                    // Audio file exists — it's playable up to last written buffer
                    logger.info("Recovered session: \(session.id) — audio file intact")
                }

                // Rename partial transcript if it exists
                let partialURL = folder.appendingPathComponent("transcript.partial.json")
                let transcriptURL = folder.appendingPathComponent("transcript.json")
                if fileManager.fileExists(atPath: partialURL.path) && !fileManager.fileExists(atPath: transcriptURL.path) {
                    try? fileManager.moveItem(at: partialURL, to: transcriptURL)
                    logger.info("Recovered partial transcript for: \(session.id)")
                }

                // Update metadata
                if let encoded = try? encoder.encode(session) {
                    try? encoded.write(to: metadataURL, options: .atomic)
                }

                recoveredIDs.append(session.id)
                Analytics.sessionRecovered(sessionID: session.id)
                logger.info("Session recovered: \(session.id)")
            }
        }

        return recoveredIDs
    }
}
