import SwiftUI
import WhisperKit

struct SessionDetailView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var recordingManager: RecordingManager
    @EnvironmentObject var transcriptionEngine: TranscriptionEngine
    @EnvironmentObject var diarizationManager: DiarizationManager

    @Binding var selectedSessionID: String?
    @State private var loadedTranscript: Transcript?

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
        .onChange(of: selectedSessionID) {
            loadTranscriptIfNeeded()
        }
        .onChange(of: transcriptionEngine.state) {
            // Reload transcript when transcription completes
            if transcriptionEngine.state == .complete {
                loadTranscriptIfNeeded()
            }
        }
        .onAppear {
            loadTranscriptIfNeeded()
        }
    }

    private func loadTranscriptIfNeeded() {
        if let id = selectedSessionID {
            loadedTranscript = sessionStore.loadTranscript(for: id)
        } else {
            loadedTranscript = nil
        }
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
            if case .transcribing(let progress) = transcriptionEngine.state,
               transcriptionEngine.activeSessionID == sessionID {
                // Transcription in progress for THIS session
                let entry = sessionStore.sessions.first { $0.id == sessionID }
                let duration = entry?.durationSeconds ?? 0
                let processedSeconds = Double(progress) * duration
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView(value: Double(progress))
                        .frame(width: 200)
                    Text("Transcribing… \(Int(progress * 100))%")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    if duration > 0 {
                        Text("\(formatTime(processedSeconds)) / \(formatTime(duration))")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            } else if let transcript = loadedTranscript {
                TranscriptView(transcript: transcript)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // No transcript yet
                VStack(spacing: 12) {
                    Spacer()
                    if case .downloading(let m) = transcriptionEngine.state {
                        ProgressView()
                            .controlSize(.regular)
                        Text("Downloading model \(m)…")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Transcription will be available once the download completes.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else if case .loading(let m) = transcriptionEngine.state {
                        ProgressView()
                            .controlSize(.regular)
                        Text("Loading model \(m)…")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    } else if case .error(let msg) = transcriptionEngine.state {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text("Model Error")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    } else {
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
                                    if let transcript = await transcriptionEngine.transcribe(
                                        audioPath: audioPath,
                                        duration: entry?.durationSeconds ?? 0,
                                        sessionID: sessionID
                                    ) {
                                        if let entry {
                                            let s = Session(
                                                id: entry.id, name: entry.name,
                                                startedAt: entry.startedAt, endedAt: entry.endedAt,
                                                durationSeconds: entry.durationSeconds, status: .complete
                                            )
                                            sessionStore.saveTranscript(transcript, for: s)
                                            // Diarize off the main thread — CoreML inference would
                                            // otherwise block the UI and prevent clicking other sessions.
                                            let dm = diarizationManager
                                            let store = sessionStore
                                            Task.detached {
                                                let labeled = dm.applyingSpeakerLabels(to: transcript, audioFileURL: audioURL)
                                                await store.saveTranscript(labeled, for: s)
                                            }
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
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
