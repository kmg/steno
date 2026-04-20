import SwiftUI

@main
struct StenoApp: App {
    @StateObject private var sessionStore = SessionStore()
    @StateObject private var recordingManager = RecordingManager()
    @StateObject private var transcriptionEngine = TranscriptionEngine()
    @StateObject private var diarizationManager = DiarizationManager()
    @StateObject private var summaryEngine = SummaryEngine()
    @StateObject private var presetStore = PresetStore()
    @StateObject private var updateChecker = UpdateChecker()

    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false

    init() {
        UserDefaults.standard.register(defaults: [
            "enableCrashReporting": true,
            "enableAnalytics": true,
        ])
        Analytics.configure()
    }

    var body: some Scene {
        WindowGroup {
            if hasCompletedSetup {
                ContentView()
                    .environmentObject(sessionStore)
                    .environmentObject(recordingManager)
                    .environmentObject(transcriptionEngine)
                    .environmentObject(diarizationManager)
                    .environmentObject(summaryEngine)
                    .environmentObject(presetStore)
                    .environmentObject(updateChecker)
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
                .environmentObject(summaryEngine)
                .environmentObject(presetStore)
        } label: {
            if recordingManager.isRecording {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
            } else {
                Image("MenuBarIcon")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(sessionStore)
                .environmentObject(transcriptionEngine)
                .environmentObject(summaryEngine)
                .environmentObject(diarizationManager)
        }
    }
}
