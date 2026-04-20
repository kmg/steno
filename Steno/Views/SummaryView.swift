import MarkdownUI
import SwiftUI

struct SummaryView: View {
    @EnvironmentObject var summaryEngine: SummaryEngine
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var presetStore: PresetStore

    let transcript: Transcript
    let sessionID: String
    @Binding var contextText: String

    @State private var selectedPresetID: UUID? = SummaryPreset.fullSummary.id
    @State private var promptText: String = SummaryPreset.fullSummary.instruction
    @State private var isPromptEdited = false
    @State private var showCustomize = false
    @State private var showSavePreset = false
    @State private var showDownloadConfirm = false
    @State private var newPresetName = ""
    @State private var cachedBody: String?
    @State private var cachedMeta: SummaryMeta?
    @State private var searchText: String = ""
    @State private var copied = false

    private var summaryText: String? {
        summaryEngine.lastSummary ?? cachedBody
    }

    private var isGenerating: Bool {
        switch summaryEngine.state {
        case .downloading, .loading, .generating: true
        default: false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let summary = summaryText {
                summaryContent(summary)
            } else if isGenerating {
                statusView
            } else if case .error(let msg) = summaryEngine.state {
                errorState(msg)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadCached() }
        .sheet(isPresented: $showSavePreset) { savePresetSheet }
        .sheet(isPresented: $showDownloadConfirm) { downloadConfirmSheet }
    }

    private func loadCached() {
        guard summaryEngine.lastSummary == nil,
              let loaded = sessionStore.loadSummary(for: sessionID) else { return }
        cachedBody = loaded.body
        cachedMeta = loaded.meta
        if let meta = loaded.meta, !meta.instruction.isEmpty {
            promptText = meta.instruction
            if let preset = presetStore.presets.first(where: {
                $0.instruction == meta.instruction
            }) {
                selectedPresetID = preset.id
                isPromptEdited = false
            } else {
                selectedPresetID = nil
                isPromptEdited = true
            }
        }
        summaryEngine.state = .complete
    }

    // MARK: - Summary Content

    private func summaryContent(_ summary: String) -> some View {
        VStack(spacing: 0) {
            InlineSearchBar(
                searchText: $searchText,
                placeholder: "Search summary",
                copied: $copied,
                onCopy: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary, forType: .string)
                }
            )

            Divider()

            ScrollView {
                Markdown(summary)
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            // Footer: info + customize + regenerate
            HStack(spacing: 12) {
                if let info = summaryEngine.generationInfo {
                    Text(info)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if let meta = cachedMeta {
                    Text("Generated \(meta.generated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button {
                    withAnimation { showCustomize.toggle() }
                } label: {
                    Label("Customize", systemImage: "slider.horizontal.3")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Regenerate") {
                    runSummarize()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if showCustomize {
                Divider()
                customizePanel
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Generate a summary")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Runs locally on your Mac")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            HStack {
                Spacer()

                Button {
                    withAnimation { showCustomize.toggle() }
                } label: {
                    Label("Customize", systemImage: "slider.horizontal.3")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Generate Summary") {
                    if summaryEngine.isModelReady {
                        runSummarize()
                    } else {
                        showDownloadConfirm = true
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            if showCustomize {
                Divider()
                customizePanel
            }
        }
    }

    // MARK: - Status & Error

    private var statusView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.regular)
            switch summaryEngine.state {
            case .downloading(let progress):
                Text("Downloading model… \(Int(progress * 100))%")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            case .loading:
                Text("Loading model…")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            case .generating:
                Text("Summarizing…")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
            Spacer()
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Try Again") { runSummarize() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    // MARK: - Customize Panel (Disclosure)

    private var customizePanel: some View {
        VStack(spacing: 8) {
            // Preset picker
            HStack {
                Text("Preset")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $selectedPresetID) {
                    ForEach(presetStore.presets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .frame(maxWidth: 180)
                .labelsHidden()
                .onChange(of: selectedPresetID) {
                    if let id = selectedPresetID,
                       let preset = presetStore.presets.first(where: { $0.id == id }) {
                        promptText = preset.instruction
                        isPromptEdited = false
                    }
                }

                if isPromptEdited {
                    Button("Save…") {
                        newPresetName = ""
                        showSavePreset = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            // Prompt
            VStack(alignment: .leading, spacing: 2) {
                Text("Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $promptText)
                    .font(.callout)
                    .frame(height: 50)
                    .border(Color.secondary.opacity(0.2))
                    .onChange(of: promptText) {
                        if let id = selectedPresetID,
                           let preset = presetStore.presets.first(where: { $0.id == id }) {
                            isPromptEdited = promptText != preset.instruction
                        } else {
                            isPromptEdited = true
                        }
                    }
            }

            // Context
            VStack(alignment: .leading, spacing: 2) {
                Text("Context")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $contextText)
                        .font(.callout)
                        .frame(height: 36)
                        .border(Color.secondary.opacity(0.2))
                        .onChange(of: contextText) {
                            if !contextText.isEmpty {
                                sessionStore.saveContext(contextText, for: sessionID)
                            }
                        }
                    if contextText.isEmpty {
                        Text("Attendees, meeting purpose, team…")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Sheets

    private var savePresetSheet: some View {
        VStack(spacing: 16) {
            Text("Save Preset")
                .font(.headline)
            TextField("Preset name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
            HStack {
                Button("Cancel") { showSavePreset = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let preset = SummaryPreset(
                        name: newPresetName, instruction: promptText)
                    presetStore.save(preset: preset)
                    selectedPresetID = preset.id
                    isPromptEdited = false
                    showSavePreset = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newPresetName.isEmpty)
            }
        }
        .padding()
        .frame(width: 320)
    }

    private var downloadConfirmSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40))
                .foregroundStyle(.blue)
            Text("Download Summary Model")
                .font(.headline)
            Text("\(summaryEngine.selectedModel.displayName) (\(summaryEngine.selectedModel.size))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("All processing stays on your device. The model is downloaded once and works offline.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            HStack(spacing: 12) {
                Button("Cancel") { showDownloadConfirm = false }
                    .keyboardShortcut(.cancelAction)
                Button("Download & Summarize") {
                    showDownloadConfirm = false
                    runSummarize()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    // MARK: - Actions

    private func runSummarize() {
        cachedBody = nil
        cachedMeta = nil
        Task {
            let result = await summaryEngine.summarize(
                transcript: transcript, instruction: promptText,
                context: contextText.isEmpty ? nil : contextText)
            if let result {
                let presetName = selectedPresetID.flatMap { id in
                    presetStore.presets.first { $0.id == id }?.name
                }
                let meta = SummaryMeta(
                    instruction: promptText,
                    presetName: presetName,
                    context: contextText.isEmpty ? nil : contextText,
                    generated: Date(),
                    model: SummaryEngine.currentModelID
                )
                sessionStore.saveSummary(result, meta: meta, for: sessionID)
                cachedBody = result
                cachedMeta = meta
            }
        }
    }
}
