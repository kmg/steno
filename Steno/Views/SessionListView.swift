import SwiftUI

struct SessionListView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var recordingManager: RecordingManager
    @EnvironmentObject var transcriptionEngine: TranscriptionEngine
    @EnvironmentObject var diarizationManager: DiarizationManager

    @Binding var selectedSessionID: String?

    @State private var renamingSessionID: String?
    @State private var renameText: String = ""
    @State private var importError: String?
    @State private var searchText: String = ""
    @State private var transcriptCache: [String: String] = [:]

    private var filteredSessions: [SessionIndex.SessionEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return sessionStore.sessions }
        return sessionStore.sessions.filter { session in
            if session.name.lowercased().contains(query) { return true }
            if let text = transcriptCache[session.id], text.contains(query) { return true }
            return false
        }
    }

    var body: some View {
        List(selection: $selectedSessionID) {
            Section("Sessions") {
            // Active recording at top
            if recordingManager.isRecording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recording...")
                            .font(.body)
                            .fontWeight(.medium)
                        Text(formatTime(recordingManager.elapsedTime))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.red.opacity(0.05))
            }

            // Past sessions (filtered if a search query is active)
            ForEach(filteredSessions) { session in
                sessionRow(session)
                    .tag(session.id)
                    .contextMenu { contextMenu(for: session) }
            }
            } // end Section
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Import Audio...") {
                        importAudio()
                    }
                    Button("Open Folder in Finder") {
                        NSWorkspace.shared.open(sessionStore.baseURL)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("Session actions")
            }
        }
        .alert("Import Failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {} message: {
            Text(importError ?? "")
        }
        .searchable(text: $searchText, prompt: "Search sessions and transcripts")
        .task(id: sessionStore.sessions.count) {
            // Load transcript texts in background for the content-search index.
            // Re-runs whenever the session count changes (new recording, deletion).
            await loadTranscriptCache()
        }
    }

    private func loadTranscriptCache() async {
        let sessions = sessionStore.sessions
        let base = sessionStore.baseURL
        let cache = await Task.detached { () -> [String: String] in
            var result: [String: String] = [:]
            for session in sessions {
                let url = base.appendingPathComponent(session.path).appendingPathComponent("transcript.json")
                guard let data = try? Data(contentsOf: url),
                      let transcript = try? JSONDecoder().decode(Transcript.self, from: data)
                else { continue }
                let joined = transcript.segments.map(\.text).joined(separator: " ").lowercased()
                result[session.id] = joined
            }
            return result
        }.value
        await MainActor.run { transcriptCache = cache }
    }

    // MARK: - Row

    private func sessionRow(_ session: SessionIndex.SessionEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if renamingSessionID == session.id {
                TextField("Name", text: $renameText, onCommit: {
                    sessionStore.renameSession(id: session.id, newName: renameText)
                    renamingSessionID = nil
                })
                .textFieldStyle(.plain)
                .font(.body)
            } else {
                Text(session.name)
                    .font(.body)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                Text(session.startedAt, style: .date)
                if let duration = session.durationSeconds {
                    Text("·")
                    Text(formatTime(duration))
                        .monospacedDigit()
                }
                if session.hasTranscript {
                    Image(systemName: "text.alignleft")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenu(for session: SessionIndex.SessionEntry) -> some View {
        Button("Rename") {
            renameText = session.name
            renamingSessionID = session.id
        }
        Button("Re-transcribe") {
            retranscribe(session)
        }
        Divider()
        Button("Open in Finder") {
            let url = sessionStore.baseURL.appendingPathComponent(session.path)
            NSWorkspace.shared.open(url)
        }
        Divider()
        Button("Delete", role: .destructive) {
            sessionStore.deleteSession(id: session.id)
            if selectedSessionID == session.id {
                selectedSessionID = nil
            }
        }
    }

    // MARK: - Actions

    private func retranscribe(_ session: SessionIndex.SessionEntry) {
        guard let audioPath = sessionStore.audioPath(for: session.id) else { return }
        let audioURL = URL(fileURLWithPath: audioPath)
        Task {
            if let transcript = await transcriptionEngine.transcribe(
                audioPath: audioPath,
                duration: session.durationSeconds ?? 0,
                sessionID: session.id
            ) {
                let s = Session(
                    id: session.id,
                    name: session.name,
                    startedAt: session.startedAt,
                    endedAt: session.endedAt,
                    durationSeconds: session.durationSeconds,
                    status: .complete
                )
                sessionStore.saveTranscript(transcript, for: s)
                Analytics.retranscribeCompleted(duration: session.durationSeconds ?? 0, model: transcriptionEngine.modelName)
                // Diarize off the main thread — CoreML inference takes seconds
                // and would otherwise freeze the sidebar (can't click other sessions).
                let dm = diarizationManager
                let store = sessionStore
                Task.detached {
                    let labeled = dm.applyingSpeakerLabels(to: transcript, audioFileURL: audioURL)
                    await store.saveTranscript(labeled, for: s)

                    // Convert .wav → .m4a after transcription + diarization are done
                    // reading the file. Safe to trash the .wav now.
                    if audioURL.pathExtension == "wav" {
                        await AudioConverter.convertToAAC(wavURL: audioURL)
                    }
                }
            }
        }
    }

    private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Select an audio file to transcribe"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            if let session = sessionStore.importAudioFile(from: url) {
                let audioPath = sessionStore.audioFileURL(for: session).path
                if let transcript = await transcriptionEngine.transcribe(
                    audioPath: audioPath,
                    duration: session.durationSeconds ?? 0
                ) {
                    sessionStore.saveTranscript(transcript, for: session)
                    Analytics.importTranscribed(duration: session.durationSeconds ?? 0, model: transcriptionEngine.modelName)
                }
                selectedSessionID = session.id
            } else {
                importError = "Failed to import audio file."
            }
        }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
