import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var recordingManager: RecordingManager
    @EnvironmentObject var transcriptionEngine: TranscriptionEngine
    @EnvironmentObject var diarizationManager: DiarizationManager

    @State private var selectedSessionID: String?

    var body: some View {
        NavigationSplitView {
            SessionListView(selectedSessionID: $selectedSessionID)
        } detail: {
            SessionDetailView(selectedSessionID: $selectedSessionID)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                recordButton
            }
        }
        .task {
            await transcriptionEngine.loadModel()
            await diarizationManager.loadMLModel()
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
                }
            } else {
                recordingManager.startRecording(
                    sessionStore: sessionStore,
                    transcriptionEngine: transcriptionEngine,
                    diarizationManager: diarizationManager
                )
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: recordingManager.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(recordingManager.isRecording ? Color.primary : Color.red)
                if recordingManager.isRecording {
                    Text(formatTime(recordingManager.elapsedTime))
                        .monospacedDigit()
                        .font(.caption)
                }
            }
        }
        .keyboardShortcut("r", modifiers: .command)
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

extension TranscriptionEngine.State {
    var isTranscribing: Bool {
        if case .transcribing = self { return true }
        return false
    }
}
