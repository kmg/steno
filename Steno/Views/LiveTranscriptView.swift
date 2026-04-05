import SwiftUI
import WhisperKit

struct LiveTranscriptView: View {
    let confirmedSegments: [TranscriptionSegment]
    let unconfirmedSegments: [TranscriptionSegment]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(confirmedSegments, id: \.start) { segment in
                        segmentRow(segment, confirmed: true)
                    }
                    ForEach(unconfirmedSegments, id: \.start) { segment in
                        segmentRow(segment, confirmed: false)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding()
            }
            .onChange(of: confirmedSegments.count + unconfirmedSegments.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private func segmentRow(_ segment: TranscriptionSegment, confirmed: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(formatTimestamp(segment.start))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
                .monospacedDigit()

            Text(cleanText(segment.text))
                .font(.body)
                .opacity(confirmed ? 1.0 : 0.5)
                .textSelection(.enabled)
        }
    }

    private func formatTimestamp(_ seconds: Float) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func cleanText(_ text: String) -> String {
        var cleaned = text
        let pattern = #"<\|[^|]*\|>"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}
