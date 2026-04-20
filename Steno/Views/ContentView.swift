import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var recordingManager: RecordingManager
    @EnvironmentObject var transcriptionEngine: TranscriptionEngine
    @EnvironmentObject var diarizationManager: DiarizationManager
    @EnvironmentObject var summaryEngine: SummaryEngine
    @EnvironmentObject var updateChecker: UpdateChecker

    @AppStorage("autoSummarize") private var autoSummarize = false

    @State private var selectedSessionID: String?
    @State private var showConsentBanner = false
    @State private var showUpdatePopover = false
    @AppStorage("showRecordingNotice") private var showRecordingNotice = true

    private var showRecordingError: Binding<Bool> {
        Binding(
            get: { recordingManager.error != nil },
            set: { if !$0 { recordingManager.error = nil } }
        )
    }

    var body: some View {
        NavigationSplitView {
            SessionListView(selectedSessionID: $selectedSessionID)
        } detail: {
            SessionDetailView(selectedSessionID: $selectedSessionID)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                modelStatusView
                if updateChecker.showBanner, let update = updateChecker.availableUpdate {
                    updateBadge(update: update)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                recordButton
            }
        }
        .overlay(alignment: .topTrailing) {
            if showConsentBanner {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Recording Started", systemImage: "record.circle.fill")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                    Text("Inform all participants that this meeting is being recorded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Toggle("Don't show again", isOn: Binding(
                            get: { !showRecordingNotice },
                            set: { showRecordingNotice = !$0 }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption2)
                        Spacer()
                        Button("I've Notified Participants") {
                            showConsentBanner = false
                        }
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .frame(width: 260)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                .padding(.top, 8)
                .padding(.trailing, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showConsentBanner)
        .alert("Recording Error", isPresented: showRecordingError, actions: {}) {
            Text(recordingManager.error ?? "Unknown error")
        }
        .task {
            let stored = UserDefaults.standard.string(forKey: "defaultModel") ?? "large-v3_turbo"
            transcriptionEngine.modelName = stored
            await transcriptionEngine.loadModel()
            await diarizationManager.loadMLModel()
            updateChecker.startChecking()
        }
    }

    @ViewBuilder
    private var modelStatusView: some View {
        switch transcriptionEngine.state {
        case .downloading(let model):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading \(model) (\(modelSizeLabel(model)))…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .loading(let model):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading \(model)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .error(let msg):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        default:
            EmptyView()
        }
    }

    private func updateBadge(update: UpdateChecker.UpdateInfo) -> some View {
        Button {
            showUpdatePopover.toggle()
        } label: {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)
        }
        .popover(isPresented: $showUpdatePopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Steno \(update.version) available")
                    .font(.callout)
                    .fontWeight(.medium)
                HStack(spacing: 4) {
                    Text("brew upgrade steno")
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.1))
                        .cornerRadius(4)
                        .textSelection(.enabled)
                }
                HStack {
                    Link("Download DMG", destination: update.url)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        updateChecker.dismiss()
                        showUpdatePopover = false
                    }
                    .font(.caption)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .frame(width: 220)
        }
    }

    private var recordButton: some View {
        Button {
            if recordingManager.isRecording {
                if let result = recordingManager.stopRecording(
                    sessionStore: sessionStore,
                    transcriptionEngine: transcriptionEngine,
                    diarizationManager: diarizationManager
                ) {
                    selectedSessionID = result.session.id
                    if autoSummarize {
                        let sessionID = result.session.id
                        Task {
                            // Wait briefly for diarization to complete
                            try? await Task.sleep(for: .seconds(2))
                            if let transcript = sessionStore.loadTranscript(for: sessionID) {
                                let text = await summaryEngine.summarize(transcript: transcript)
                                if let text {
                                    let meta = SummaryMeta(
                                        instruction: SummaryPreset.fullSummary.instruction,
                                        presetName: "Full Summary",
                                        context: nil,
                                        generated: Date(),
                                        model: SummaryEngine.currentModelID
                                    )
                                    sessionStore.saveSummary(text, meta: meta, for: sessionID)
                                }
                            }
                        }
                    }
                }
            } else {
                recordingManager.startRecording(
                    sessionStore: sessionStore,
                    transcriptionEngine: transcriptionEngine,
                    diarizationManager: diarizationManager
                )
                if showRecordingNotice {
                    showConsentBanner = true
                }
            }
        } label: {
            HStack(spacing: 4) {
                if recordingManager.isStarting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: recordingManager.isRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(recordingManager.isRecording ? Color.primary : Color.red)
                }
                if recordingManager.isRecording {
                    Text(formatTime(recordingManager.elapsedTime))
                        .monospacedDigit()
                        .font(.caption)
                }
            }
        }
        .disabled(recordingManager.isStarting)
        .keyboardShortcut("r", modifiers: .command)
    }

    private func modelSizeLabel(_ model: String) -> String {
        switch model {
        case "tiny": "39MB"
        case "base": "74MB"
        case "small": "216MB"
        case "medium": "500MB"
        case "large-v3_turbo": "600MB"
        case "large-v3": "1.5GB"
        default: ""
        }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

extension TranscriptionEngine.State {
    var isTranscribing: Bool {
        if case .transcribing = self { return true }
        return false
    }
}
