import Foundation

struct Session: Codable, Identifiable {
    var id: String // e.g. "2026-04-04_1400_untitled"
    var name: String
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double?
    var status: Status
    var devices: Devices?

    enum Status: String, Codable {
        case recording
        case complete
        case recovered
    }

    struct Devices: Codable {
        var microphone: String?
        var systemAudio: String?
    }

    var folderName: String { id }

    static func makeID(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: date)
    }
}
