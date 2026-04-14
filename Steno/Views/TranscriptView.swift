import SwiftUI

struct TranscriptView: View {
    let transcript: Transcript

    @State private var searchText = ""
    @State private var copied = false

    private var filteredSegments: [Transcript.Segment] {
        if searchText.isEmpty { return transcript.segments }
        let query = searchText.lowercased()
        return transcript.segments.filter { $0.text.lowercased().contains(query) }
    }

    private var fullText: String {
        transcript.segments.map(\.text).joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(filteredSegments) { segment in
                    SegmentRow(segment: segment, transcript: transcript, searchText: searchText)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search transcript")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fullText, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy All", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy entire transcript (⌘⇧C)")
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
    }
}

private struct SegmentRow: View {
    let segment: Transcript.Segment
    let transcript: Transcript
    let searchText: String

    private let speakerColorPalette: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .mint, .indigo, .brown, .teal]

    var body: some View {
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
                highlightedText
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var highlightedText: Text {
        guard !searchText.isEmpty else {
            return Text(segment.text)
        }
        var attributed = AttributedString(segment.text)
        let queryLower = searchText.lowercased()
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let range = attributed[searchRange].range(of: queryLower, options: .caseInsensitive) {
            attributed[range].backgroundColor = .yellow.opacity(0.35)
            searchRange = range.upperBound..<attributed.endIndex
        }
        return Text(attributed)
    }

    private func colorForSpeaker(_ id: String) -> Color {
        if let idx = Int(id.replacingOccurrences(of: "SPEAKER_", with: "")),
           idx < speakerColorPalette.count {
            return speakerColorPalette[idx]
        }
        return .secondary
    }

    private func formatTimestamp(_ seconds: Float) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
