import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var transcriptionEngine: TranscriptionEngine

    @AppStorage("defaultModel") private var defaultModel = "large-v3-turbo"
    @AppStorage("customModelPath") private var customModelPath = ""

    @State private var micPermission: AVAudioApplication.recordPermission = .undetermined
    @State private var screenRecordingGranted = false

    private let availableModels = [
        ("tiny", "Tiny (~39MB)", "Fastest, lowest quality"),
        ("small", "Small (~216MB)", "Fast, good quality"),
        ("large-v3-turbo", "Large v3 Turbo (~600MB)", "Recommended — best quality/speed"),
        ("custom", "Custom Model", "Load from local folder"),
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
                }

                HStack {
                    Label("Screen Recording", systemImage: "tv")
                    Spacer()
                    permissionBadge(granted: screenRecordingGranted)
                    Button("Open Settings") {
                        openPrivacySettings("ScreenCapture")
                    }
                    .controlSize(.small)
                }

                Text("Microphone is prompted automatically. Screen Recording (for system audio) must be granted in System Settings → Privacy & Security.")
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
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 480)
        .onAppear { refreshPermissions() }
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
        screenRecordingGranted = checkScreenRecordingPermission()
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
