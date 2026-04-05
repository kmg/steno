import SwiftUI

@main
struct StenoApp: App {
    @StateObject private var sessionStore = SessionStore()
    @StateObject private var recordingManager = RecordingManager()
    @StateObject private var transcriptionEngine = TranscriptionEngine()
    @StateObject private var diarizationManager = DiarizationManager()

    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false

    var body: some Scene {
        WindowGroup {
            if hasCompletedSetup {
                ContentView()
                    .environmentObject(sessionStore)
                    .environmentObject(recordingManager)
                    .environmentObject(transcriptionEngine)
                    .environmentObject(diarizationManager)
            } else {
                WelcomeView(hasCompletedSetup: $hasCompletedSetup)
                    .environmentObject(transcriptionEngine)
            }
        }
        .defaultSize(width: 700, height: 500)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(sessionStore)
                .environmentObject(recordingManager)
                .environmentObject(transcriptionEngine)
                .environmentObject(diarizationManager)
        } label: {
            Image(systemName: recordingManager.isRecording ? "record.circle.fill" : "waveform")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(recordingManager.isRecording ? .red : .primary)
        }

        Settings {
            SettingsView()
                .environmentObject(transcriptionEngine)
                .environmentObject(diarizationManager)
        }
    }
}
