import Foundation

struct SummaryPreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var instruction: String
    var isDefault: Bool

    init(id: UUID = UUID(), name: String, instruction: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.instruction = instruction
        self.isDefault = isDefault
    }

    static let fullSummary = SummaryPreset(
        name: "Full Summary",
        instruction: """
            Summarize this meeting. Include:
            - **Overview**: What the meeting was about (2-3 sentences)
            - **Key Takeaways**: Important decisions, insights, or conclusions
            - **Action Items**: What needs to happen next, with owners if identifiable

            Use markdown. Be concise.
            """,
        isDefault: true
    )
}

@MainActor
final class PresetStore: ObservableObject {
    @Published var presets: [SummaryPreset] = [.fullSummary]

    private let fileManager = FileManager.default
    private var presetsURL: URL {
        SessionStore.storedBaseURL().appendingPathComponent("presets.json")
    }

    init() {
        load()
    }

    func save(preset: SummaryPreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
        } else {
            presets.append(preset)
        }
        persist()
    }

    func delete(preset: SummaryPreset) {
        guard !preset.isDefault else { return }
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    private func load() {
        guard fileManager.fileExists(atPath: presetsURL.path) else { return }
        do {
            let data = try Data(contentsOf: presetsURL)
            let loaded = try JSONDecoder().decode([SummaryPreset].self, from: data)
            if !loaded.isEmpty {
                presets = loaded
            }
        } catch {
            // Keep defaults on failure
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(presets)
            try data.write(to: presetsURL, options: .atomic)
        } catch {
            // Silent failure — presets are non-critical
        }
    }
}
