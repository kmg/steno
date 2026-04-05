import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var transcriptionEngine: TranscriptionEngine

    @AppStorage("defaultModel") private var defaultModel = "tiny"
    @AppStorage("customModelPath") private var customModelPath = ""

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
        .frame(width: 500, height: 400)
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
