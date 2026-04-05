import Foundation

struct Speaker: Codable, Identifiable, Hashable {
    var id: String       // e.g. "SPEAKER_0", "SPEAKER_1"
    var source: Source?
    var label: String    // Display name: "Speaker 1", "Speaker 2"

    enum Source: String, Codable {
        case mlIdentification
    }
}
