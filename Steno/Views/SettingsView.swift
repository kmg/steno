import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var transcriptionEngine: TranscriptionEngine

    @AppStorage("defaultModel") private var defaultModel = "large-v3_turbo"
    @AppStorage("customModelPath") private var customModelPath = ""

    @AppStorage("enableCrashReporting") private var enableCrashReporting = true
    @AppStorage("enableAnalytics") private var enableAnalytics = true

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
                    }
                    .onChange(of: customModelPath) {
                        if !customModelPath.isEmpty {
                            transcriptionEngine.customModelFolder = customModelPath
                            transcriptionEngine.modelName = "custom"
                        }
                    }

                    Text("Point to a folder containing compiled Core ML models (.mlmodelc files). Convert Whisper models with [whisperkittools](https://github.com/argmaxinc/whisperkittools).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Models download from HuggingFace on first use. Cache: ~/.cache/huggingface/hub/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                HStack {
                    Label("Microphone", systemImage: "mic.fill")
                    Spacer()
                    permissionBadge(granted: micPermission == .granted)
                    Button("Open Settings") {
                        openPrivacySettings("Microphone")
                    }
                    .controlSize(.small)
                }

                HStack {
                    Label("System Audio", systemImage: "speaker.wave.2.fill")
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
                    Text("~/Documents/Steno/")
                        .foregroundStyle(.secondary)
                    Button("Open") {
                        let url = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("Documents")
                            .appendingPathComponent("Steno")
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Section("Privacy & Diagnostics") {
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
        .frame(width: 500, height: 580)
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
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
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

    private func browseForModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing WhisperKit Core ML models"

        if panel.runModal() == .OK, let url = panel.url {
            customModelPath = url.path
        }
    }
}
