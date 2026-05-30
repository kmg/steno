import Foundation

struct SessionIndex: Codable {
    var sessions: [SessionEntry]

    enum CodingKeys: String, CodingKey {
        case sessions
    }

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

        enum CodingKeys: String, CodingKey {
            case id, name, startedAt, endedAt, durationSeconds, model, path
            case hasAudio, hasTranscript, segmentCount, languagesDetected
        }
    }
}
