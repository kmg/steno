import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var transcriptionEngine: TranscriptionEngine

    @AppStorage("defaultModel") private var defaultModel = "large-v3_turbo"
    @AppStorage("customModelPath") private var customModelPath = ""

    @AppStorage("enableCrashReporting") private var enableCrashReporting = true
    @AppStorage("enableAnalytics") private var enableAnalytics = true
    @AppStorage("showRecordingNotice") private var showRecordingNotice = true

    @State private var micPermission: AVAudioApplication.recordPermission = .undetermined
    @State private var systemAudioGranted = false

    private let availableModels = [
        ("tiny", "Tiny (39MB)", "Quick test — gets the gist, misses details"),
        ("small", "Small (216MB)", "Casual notes — good for clear 1-on-1 audio"),
        ("large-v3_turbo", "Large Turbo (600MB)", "Recommended — handles accents, crosstalk, background noise"),
        ("large-v3", "Large (1.5GB)", "Maximum accuracy — slower, best for difficult audio"),
        ("custom", "Custom Model", "Load your own fine-tuned model from disk"),
    ]

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            DebugTabView()
                .tabItem { Label("Debug", systemImage: "ladybug") }
        }
        // Settings window is sized to fit the larger of the two tabs.
        // Debug needs ~720pt to show 5 subsystem cells + filter chips +
        // Level picker without clipping; height needs to leave room for
        // the action bar at the bottom.
        .frame(minWidth: 720, minHeight: 600)
    }

    private var generalTab: some View {
        Form {
            Section("Transcription") {
                Picker("Default Model", selection: $defaultModel) {
                    ForEach(availableModels, id: \.0) { model in
                        VStack(alignment: .leading) {
                            Text(model.1)
                            Text(model.2)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(model.0)
                    }
                }
                .onChange(of: defaultModel) {
                    if defaultModel != "custom" {
                        transcriptionEngine.modelName = defaultModel
                        transcriptionEngine.customModelFolder = nil
                        Task { await transcriptionEngine.loadModel() }
                    }
                }

                modelStatusRow

                if defaultModel == "custom" {
                    HStack {
                        TextField("Model folder path", text: $customModelPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") {
                            browseForModelFolder()
                        }
                        Button("Load") {
                            guard !customModelPath.isEmpty else { return }
                            transcriptionEngine.customModelFolder = customModelPath
                            transcriptionEngine.modelName = "custom"
                            Task { await transcriptionEngine.loadModel() }
                        }
                        .disabled(customModelPath.isEmpty)
                    }

                    Text("Point to a folder containing compiled Core ML models (.mlmodelc files). Convert Whisper models with [whisperkittools](https://github.com/argmaxinc/whisperkittools).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Transcription models download on first use and run locally on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                HStack {
                    Label("Microphone", systemImage: "mic")
                    Spacer()
                    permissionBadge(granted: micPermission == .granted)
                    Button("Open Settings") {
                        openPrivacySettings("Microphone")
                    }
                    .controlSize(.small)
                }

                HStack {
                    Label("System Audio", systemImage: "speaker.wave.2")
                    Spacer()
                    permissionBadge(granted: systemAudioGranted)
                    Button("Open Settings") {
                        openPrivacySettings("ScreenCapture")
                    }
                    .controlSize(.small)
                }

                Text("Both permissions are requested when you start recording. If denied, grant them in System Settings → Privacy & Security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                HStack {
                    Text("Recordings folder")
                    Spacer()
                    Text(sessionStore.baseURL.path.replacingOccurrences(
                        of: FileManager.default.homeDirectoryForCurrentUser.path,
                        with: "~"))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Spacer()
                    Button("Open in Finder") {
                        NSWorkspace.shared.open(sessionStore.baseURL)
                    }
                    Button("Change…") {
                        browseForRecordingsFolder()
                    }
                }
            }

            Section("Privacy & Diagnostics") {
                Toggle("Remind me to notify participants", isOn: $showRecordingNotice)
                Text("Shows a reminder when you start recording. You are responsible for complying with recording consent laws in your jurisdiction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Send Crash Reports", isOn: $enableCrashReporting)
                Text("Sends crash data to help fix bugs. No audio, transcripts, or file paths included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Usage Analytics", isOn: $enableAnalytics)
                    .onChange(of: enableAnalytics) {
                        Analytics.syncPostHogOptOut()
                    }
                Text("Sends anonymous usage events (recording duration, model used, locale) to help improve Steno. No identifying information collected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Relaxed from a hard frame so the TabView's outer .frame(minWidth:720)
        // can stretch the window to fit the Debug tab without clipping.
        .frame(minWidth: 500, minHeight: 580)
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    @ViewBuilder
    private var modelStatusRow: some View {
        HStack {
            Text("Status")
            Spacer()
            switch transcriptionEngine.state {
            case .downloading(let model):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Downloading \(model)…")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            case .loading(let model):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading \(model)…")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            case .error(let msg):
                HStack(spacing: 6) {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("Retry") {
                        Task { await transcriptionEngine.loadModel() }
                    }
                    .controlSize(.small)
                }
            case .idle, .complete:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Ready")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            case .streaming, .transcribing:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("In use")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private func permissionBadge(granted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            Text(granted ? "Granted" : "Not Granted")
                .font(.caption)
                .foregroundStyle(granted ? .green : .orange)
        }
    }

    private func refreshPermissions() {
        micPermission = AVAudioApplication.shared.recordPermission
        systemAudioGranted = checkScreenRecordingPermission()
    }

    private func checkScreenRecordingPermission() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return windowList.contains { dict in
            guard let pid = dict[kCGWindowOwnerPID as String] as? Int32 else { return false }
            return pid != ownPID
        }
    }

    private func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func browseForRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for Steno recordings"
        panel.prompt = "Use This Folder"

        if panel.runModal() == .OK, let url = panel.url {
            sessionStore.changeBaseURL(to: url)
        }
    }

    private func browseForModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing WhisperKit Core ML models"

        if panel.runModal() == .OK, let url = panel.url {
            customModelPath = url.path
            transcriptionEngine.customModelFolder = customModelPath
            transcriptionEngine.modelName = "custom"
            Task { await transcriptionEngine.loadModel() }
        }
    }
}
