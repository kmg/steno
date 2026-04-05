import SwiftUI
import WhisperKit

struct SessionDetailView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var recordingManager: RecordingManager
    @EnvironmentObject var transcriptionEngine: TranscriptionEngine
    @EnvironmentObject var diarizationManager: DiarizationManager

    @Binding var selectedSessionID: String?

    var body: some View {
        VStack(spacing: 0) {
            if recordingManager.isRecording {
                recordingView
            } else if let sessionID = selectedSessionID {
                savedSessionView(sessionID: sessionID)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Recording View

    private var recordingView: some View {
        VStack(spacing: 0) {
            // Recording header
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text("Recording")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Spacer()
                    Text(formatTime(recordingManager.elapsedTime))
                        .font(.title2)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                statusBadge
            }
            .padding()

            Divider()

            // Live transcript
            if !transcriptionEngine.liveConfirmedSegments.isEmpty ||
               !transcriptionEngine.liveUnconfirmedSegments.isEmpty {
                LiveTranscriptView(
                    confirmedSegments: transcriptionEngine.liveConfirmedSegments,
                    unconfirmedSegments: transcriptionEngine.liveUnconfirmedSegments
                )
            } else {
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for speech...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Saved Session

    private func savedSessionView(sessionID: String) -> some View {
        VStack(spacing: 0) {
            if let transcript = sessionStore.loadTranscript(for: sessionID) {
                TranscriptView(transcript: transcript)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "text.page.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No transcript")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    if let audioPath = sessionStore.audioPath(for: sessionID) {
                        Button("Transcribe Now") {
                            let entry = sessionStore.sessions.first { $0.id == sessionID }
                            let audioURL = URL(fileURLWithPath: audioPath)
                            Task {
                                if var transcript = await transcriptionEngine.transcribe(
                                    audioPath: audioPath,
                                    duration: entry?.durationSeconds ?? 0
                                ) {
                                    diarizationManager.applySpeakerLabels(to: &transcript, audioFileURL: audioURL)
                                    if let entry {
                                        let s = Session(
                                            id: entry.id, name: entry.name,
                                            startedAt: entry.startedAt, endedAt: entry.endedAt,
                                            durationSeconds: entry.durationSeconds, status: .complete
                                        )
                                        sessionStore.saveTranscript(transcript, for: s)
                                    }
                                }
                            }
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Steno")
                .font(.largeTitle)
                .fontWeight(.medium)
            Text("Press record or select a session")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Status Badge

    @ViewBuilder
    private var statusBadge: some View {
        switch transcriptionEngine.state {
        case .loading(let model):
            badge("Loading \(model)...", icon: "arrow.down.circle")
        case .streaming:
            badge("Live transcription", icon: "waveform")
        case .transcribing:
            badge("Transcribing...", icon: "text.magnifyingglass")
        case .error(let msg):
            Text(msg).font(.caption).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private func badge(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption)
        }
        .foregroundStyle(.secondary)
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
