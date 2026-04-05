import SwiftUI

struct TranscriptView: View {
    let transcript: Transcript

    private let speakerColorPalette: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .mint, .indigo, .brown, .teal]

    private func colorForSpeaker(_ id: String) -> Color {
        if let idx = Int(id.replacingOccurrences(of: "SPEAKER_", with: "")),
           idx < speakerColorPalette.count {
            return speakerColorPalette[idx]
        }
        return .secondary
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(transcript.segments) { segment in
                    HStack(alignment: .top, spacing: 12) {
                        Text(formatTimestamp(segment.start))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                            .monospacedDigit()

                        VStack(alignment: .leading, spacing: 2) {
                            if let speakerID = segment.speaker,
                               let speaker = transcript.speakers?[speakerID] {
                                Text(speaker.label)
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(colorForSpeaker(speakerID))
                            }
                            Text(segment.text)
                                .font(.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatTimestamp(_ seconds: Float) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
