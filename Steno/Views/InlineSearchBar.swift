import SwiftUI

struct InlineSearchBar: View {
    @Binding var searchText: String
    var placeholder: String = "Search…"
    @Binding var copied: Bool
    var onCopy: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField(placeholder, text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button {
                onCopy()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy All", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
