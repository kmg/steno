import SwiftUI
import AVFoundation

struct WelcomeView: View {
    @EnvironmentObject var transcriptionEngine: TranscriptionEngine
    @AppStorage("defaultModel") private var defaultModel = "large-v3-turbo"
    @Binding var hasCompletedSetup: Bool

    @State private var selectedModel = "large-v3-turbo"

    private let models = [
        ("large-v3-turbo", "Large v3 Turbo", "~600MB — Best quality/speed balance", true),
        ("small", "Small", "~216MB — Faster, good quality", false),
        ("tiny", "Tiny", "~39MB — Fastest, lowest quality", false),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            Text("Welcome to Steno")
                .font(.title)
                .fontWeight(.semibold)
                .padding(.top, 12)

            Text("Local transcription on your Mac. No data leaves your machine.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
                .padding(.horizontal, 40)

            // Model selection
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcription Model")
                        .font(.headline)

                    ForEach(models, id: \.0) { model in
                        HStack {
                            Image(systemName: selectedModel == model.0 ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedModel == model.0 ? .blue : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(model.1)
                                        .fontWeight(model.3 ? .medium : .regular)
                                    if model.3 {
                                        Text("Recommended")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(.blue.opacity(0.15))
                                            .foregroundStyle(.blue)
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(model.2)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedModel = model.0 }
                    }

                    Text("Downloads on first use. You can record immediately — transcription starts once the model is ready.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(4)
            }
            .padding(.horizontal, 40)
            .padding(.top, 16)

            // Permissions + first launch note
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Setup Notes")
                        .font(.headline)

                    noteRow(
                        icon: "lock.shield",
                        title: "Unsigned App",
                        detail: "macOS may warn this app is damaged. Go to System Settings → Privacy & Security → scroll down → click \"Open Anyway\"."
                    )
                    noteRow(
                        icon: "mic.fill",
                        title: "Microphone",
                        detail: "Prompted automatically on first recording."
                    )
                    noteRow(
                        icon: "tv",
                        title: "Screen Recording (optional)",
                        detail: "For system audio capture. Grant in System Settings → Privacy & Security → Screen Recording."
                    )
                }
                .padding(4)
            }
            .padding(.horizontal, 40)
            .padding(.top, 12)

            Spacer(minLength: 20)

            Button {
                defaultModel = selectedModel
                transcriptionEngine.modelName = selectedModel
                hasCompletedSetup = true
            } label: {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .frame(width: 480, height: 580)
    }

    private func noteRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
