import SwiftUI

struct SessionListView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var recordingManager: RecordingManager
    @EnvironmentObject var transcriptionEngine: TranscriptionEngine
    @EnvironmentObject var diarizationManager: DiarizationManager

    @Binding var selectedSessionID: String?
    @State private var renamingSessionID: String?
    @State private var renameText: String = ""

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

            // Past sessions
            ForEach(sessionStore.sessions) { session in
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
            }
        }
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
        let audioURL = sessionStore.baseURL
            .appendingPathComponent(session.path)
            .appendingPathComponent("audio.m4a")
        Task {
            if var transcript = await transcriptionEngine.transcribe(
                audioPath: audioPath,
                duration: session.durationSeconds ?? 0
            ) {
                // Apply ML diarization on re-transcribe (Layer 2)
                diarizationManager.applySpeakerLabels(to: &transcript, audioFileURL: audioURL)

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
