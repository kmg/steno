import Foundation
import AVFoundation
import os

@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [SessionIndex.SessionEntry] = []
    @Published var currentSession: Session?

    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "SessionStore")
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    var baseURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
            .appendingPathComponent("Steno")
    }

    init() {
        ensureBaseDirectory()
        let recovered = CrashRecovery.recoverSessions(in: baseURL)
        if !recovered.isEmpty {
            logger.info("Recovered \(recovered.count) interrupted sessions")
        }
        loadIndex()
    }

    private func ensureBaseDirectory() {
        if !fileManager.fileExists(atPath: baseURL.path) {
            do {
                try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
                logger.info("Created ~/Transcripts/")
            } catch {
                logger.error("Failed to create Transcripts dir: \(error)")
            }
        }
    }

    // MARK: - Session Lifecycle

    func startSession() -> Session {
        let now = Date()
        let id = Session.makeID(date: now)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        let name = formatter.string(from: now)
        let session = Session(
            id: id,
            name: name,
            startedAt: now,
            status: .recording,
            devices: Session.Devices(microphone: "Default Microphone")
        )

        // Create session folder
        let folderURL = baseURL.appendingPathComponent(session.folderName)
        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create session folder: \(error)")
        }

        // Write initial metadata
        writeMetadata(session)
        currentSession = session
        return session
    }

    func finishSession(duration: TimeInterval) {
        guard var session = currentSession else { return }
        session.endedAt = Date()
        session.durationSeconds = duration
        session.status = .complete

        writeMetadata(session)
        updateIndex(session: session)
        currentSession = nil
    }

    // MARK: - File Paths

    func sessionFolderURL(for session: Session) -> URL {
        baseURL.appendingPathComponent(session.folderName)
    }

    func audioFileURL(for session: Session) -> URL {
        sessionFolderURL(for: session).appendingPathComponent("audio.m4a")
    }

    func metadataURL(for session: Session) -> URL {
        sessionFolderURL(for: session).appendingPathComponent("metadata.json")
    }

    func indexURL() -> URL {
        baseURL.appendingPathComponent("sessions.json")
    }

    func transcriptURL(for session: Session) -> URL {
        sessionFolderURL(for: session).appendingPathComponent("transcript.json")
    }

    func partialTranscriptURL(for session: Session) -> URL {
        sessionFolderURL(for: session).appendingPathComponent("transcript.partial.json")
    }

    /// Save partial transcript during recording (for crash recovery).
    func savePartialTranscript(_ transcript: Transcript, for session: Session) {
        let url = partialTranscriptURL(for: session)
        do {
            let data = try encoder.encode(transcript)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to write partial transcript: \(error)")
        }
    }

    func audioPath(for sessionID: String) -> String? {
        guard let entry = sessions.first(where: { $0.id == sessionID }) else { return nil }
        return baseURL
            .appendingPathComponent(entry.path)
            .appendingPathComponent("audio.m4a")
            .path
    }

    // MARK: - Transcript

    func saveTranscript(_ transcript: Transcript, for session: Session) {
        let url = transcriptURL(for: session)
        do {
            let data = try encoder.encode(transcript)
            try data.write(to: url, options: .atomic)

            // Update index entry
            if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[idx].hasTranscript = true
                sessions[idx].segmentCount = transcript.segments.count
                sessions[idx].model = transcript.model

                // Auto-name from first transcript text if not manually renamed
                if let firstText = transcript.segments.first?.text, !firstText.isEmpty {
                    let autoName = String(firstText.prefix(40)).trimmingCharacters(in: .whitespaces)
                    if !autoName.isEmpty {
                        sessions[idx].name = autoName
                    }
                }

                writeIndex()
            }
        } catch {
            logger.error("Failed to write transcript: \(error)")
        }
    }

    func loadTranscript(for sessionID: String) -> Transcript? {
        guard let entry = sessions.first(where: { $0.id == sessionID }) else { return nil }
        let url = baseURL
            .appendingPathComponent(entry.path)
            .appendingPathComponent("transcript.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(Transcript.self, from: data)
        } catch {
            logger.error("Failed to load transcript: \(error)")
            return nil
        }
    }

    // MARK: - Persistence

    private func writeMetadata(_ session: Session) {
        let url = metadataURL(for: session)
        do {
            let data = try encoder.encode(session)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to write metadata: \(error)")
        }
    }

    private func updateIndex(session: Session) {
        let entry = SessionIndex.SessionEntry(
            id: session.id,
            name: session.name,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            durationSeconds: session.durationSeconds,
            model: nil,
            path: session.folderName,
            hasAudio: true,
            hasTranscript: false,
            segmentCount: nil,
            languagesDetected: nil
        )

        // Remove existing entry for this ID, add new one at front
        sessions.removeAll { $0.id == session.id }
        sessions.insert(entry, at: 0)
        writeIndex()
    }

    private func writeIndex() {
        let index = SessionIndex(sessions: sessions)
        let url = indexURL()
        do {
            let data = try encoder.encode(index)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to write sessions index: \(error)")
        }
    }

    private func loadIndex() {
        let url = indexURL()
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let index = try decoder.decode(SessionIndex.self, from: data)
            sessions = index.sessions
        } catch {
            logger.error("Failed to load sessions index: \(error)")
        }
    }

    // MARK: - Session Management

    func renameSession(id: String, newName: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].name = newName
        writeIndex()

        // Also update metadata.json on disk
        let metaURL = baseURL
            .appendingPathComponent(sessions[idx].path)
            .appendingPathComponent("metadata.json")
        if let data = try? Data(contentsOf: metaURL),
           var session = try? decoder.decode(Session.self, from: data) {
            session.name = newName
            if let encoded = try? encoder.encode(session) {
                try? encoded.write(to: metaURL, options: .atomic)
            }
        }
    }

    func deleteSession(id: String) {
        guard let entry = sessions.first(where: { $0.id == id }) else { return }
        let folderURL = baseURL.appendingPathComponent(entry.path)
        do {
            try fileManager.trashItem(at: folderURL, resultingItemURL: nil)
        } catch {
            // Fallback to direct removal if trash fails
            do {
                try fileManager.removeItem(at: folderURL)
            } catch {
                logger.error("Failed to delete session folder: \(error)")
            }
        }
        sessions.removeAll { $0.id == id }
        writeIndex()
    }

    func importAudioFile(from sourceURL: URL) -> Session? {
        let now = Date()
        let name = sourceURL.deletingPathExtension().lastPathComponent
        let id = Session.makeID(date: now)
        let session = Session(
            id: id, name: name, startedAt: now, endedAt: now,
            durationSeconds: audioDuration(url: sourceURL),
            status: .complete
        )

        let folderURL = baseURL.appendingPathComponent(session.folderName)
        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let destURL = folderURL.appendingPathComponent("audio.m4a")
            try fileManager.copyItem(at: sourceURL, to: destURL)
            writeMetadata(session)
            updateIndex(session: session)
            return session
        } catch {
            logger.error("Failed to import audio: \(error)")
            return nil
        }
    }

    private func audioDuration(url: URL) -> Double? {
        let asset = AVURLAsset(url: url)
        let duration = asset.duration
        guard duration.timescale > 0 else { return nil }
        return Double(duration.value) / Double(duration.timescale)
    }
}
