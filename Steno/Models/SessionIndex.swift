import Foundation

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
    }
}
