import SwiftUI

@main
struct StenoApp: App {
    @StateObject private var sessionStore = SessionStore()
    @StateObject private var recordingManager = RecordingManager()
    @StateObject private var transcriptionEngine = TranscriptionEngine()
    @StateObject private var diarizationManager = DiarizationManager()
    @StateObject private var updateChecker = UpdateChecker()

    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false

    init() {
        UserDefaults.standard.register(defaults: [
            "enableCrashReporting": true,
            "enableAnalytics": true,
        ])
        Self.resetToolbarStateIfNeeded()
        Analytics.configure()
    }

    /// One-time toolbar/window state reset per app version.
    /// v0.2.22 launches crashed inside `NSToolbar _insertNewItemWithItemIdentifier`
    /// when AppKit tried to restore a serialized toolbar layout from a previous
    /// version that referenced item identifiers no longer present (the
    /// .searchable move + new toolbar items in v0.2.22 changed the layout shape).
    /// Wipe the persisted toolbar state once per version to force a clean
    /// rebuild — small UX cost (toolbar customization resets), big crash fix.
    private static func resetToolbarStateIfNeeded() {
        let versionKey = "stenoToolbarStateResetVersion"
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let lastReset = UserDefaults.standard.string(forKey: versionKey)
        guard lastReset != currentVersion else { return }
        for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.contains("NSToolbar") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(currentVersion, forKey: versionKey)
    }

    var body: some Scene {
        WindowGroup {
            if hasCompletedSetup {
                ContentView()
                    .environmentObject(sessionStore)
                    .environmentObject(recordingManager)
                    .environmentObject(transcriptionEngine)
                    .environmentObject(diarizationManager)
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
                .environmentObject(diarizationManager)
        }
    }
}
