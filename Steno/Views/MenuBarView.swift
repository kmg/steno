import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var recordingManager: RecordingManager
    @EnvironmentObject var transcriptionEngine: TranscriptionEngine
    @EnvironmentObject var diarizationManager: DiarizationManager

    var body: some View {
        if recordingManager.isRecording {
            Button("Stop Recording (\(formatTime(recordingManager.elapsedTime)))") {
                _ = recordingManager.stopRecording(
                    sessionStore: sessionStore,
                    transcriptionEngine: transcriptionEngine,
                    diarizationManager: diarizationManager
                )
            }
            .keyboardShortcut("r", modifiers: .command)
        } else {
            Button("Start Recording") {
                recordingManager.startRecording(
                    sessionStore: sessionStore,
                    transcriptionEngine: transcriptionEngine,
                    diarizationManager: diarizationManager
                )
            }
            .keyboardShortcut("r", modifiers: .command)
        }

        Divider()

        if let latest = sessionStore.sessions.first {
            Text("Latest: \(latest.name)")
                .foregroundStyle(.secondary)
        }

        Divider()

        Button("Show Window") {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            }
        }

        SettingsLink {
            Text("Settings...")
        }

        Divider()

        Button("Quit Steno") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
