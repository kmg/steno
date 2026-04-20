import Foundation

struct SummaryMeta: Equatable {
    var instruction: String
    var presetName: String?
    var context: String?
    var generated: Date
    var model: String

    func toFrontmatter() -> String {
        let formatter = ISO8601DateFormatter()
        var lines = ["---"]
        lines.append("instruction: \(yamlEscape(instruction))")
        if let presetName { lines.append("preset: \(yamlEscape(presetName))") }
        if let context, !context.isEmpty { lines.append("context: \(yamlEscape(context))") }
        lines.append("generated: \(formatter.string(from: generated))")
        lines.append("model: \(model)")
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    static func parse(from text: String) -> (meta: SummaryMeta?, body: String) {
        guard text.hasPrefix("---\n") else { return (nil, text) }
        let parts = text.components(separatedBy: "\n---\n")
        guard parts.count >= 2 else { return (nil, text) }

        let header = parts[0].dropFirst(4) // drop leading "---\n"
        let body = parts.dropFirst().joined(separator: "\n---\n")

        var instruction = ""
        var presetName: String?
        var context: String?
        var generated = Date()
        var model = ""

        for line in header.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let value = extractYAML(key: "instruction", from: trimmed) {
                instruction = value
            } else if let value = extractYAML(key: "preset", from: trimmed) {
                presetName = value
            } else if let value = extractYAML(key: "context", from: trimmed) {
                context = value
            } else if let value = extractYAML(key: "generated", from: trimmed) {
                let formatter = ISO8601DateFormatter()
                generated = formatter.date(from: value) ?? Date()
            } else if let value = extractYAML(key: "model", from: trimmed) {
                model = value
            }
        }

        let meta = SummaryMeta(
            instruction: instruction, presetName: presetName,
            context: context, generated: generated, model: model)
        return (meta, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func yamlEscape(_ s: String) -> String {
        if s.contains("\n") || s.contains(":") || s.contains("\"") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n"))\""
        }
        return s
    }

    private static func extractYAML(key: String, from line: String) -> String? {
        let prefix = "\(key): "
        guard line.hasPrefix(prefix) else { return nil }
        var value = String(line.dropFirst(prefix.count))
        // Strip surrounding quotes
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
            value = value.replacingOccurrences(of: "\\\"", with: "\"")
            value = value.replacingOccurrences(of: "\\n", with: "\n")
        }
        return value
    }
}

struct SessionIndex: Codable {
    var sessions: [SessionEntry]

    struct SessionEntry: Codable, Identifiable {
        var id: String
        var name: String
        var startedAt: Date
        var endedAt: Date?
        var durationSeconds: Double?
        var model: String?
        var path: String
        var hasAudio: Bool
        var hasTranscript: Bool
        var segmentCount: Int?
        var languagesDetected: [String]?
        var hasSummary: Bool?
    }
}
