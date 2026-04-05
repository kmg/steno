import Foundation

struct Speaker: Codable, Identifiable, Hashable {
    var id: String          // e.g. "SPEAKER_LOCAL", "SPEAKER_REMOTE_1", "SPEAKER_0"
    var source: Source?
    var label: String       // Display name: "You", "Remote", "Speaker 1"

    enum Source: String, Codable {
        case microphone
        case systemAudio
        case mlDiarization
    }

    static let local = Speaker(id: "SPEAKER_LOCAL", source: .microphone, label: "You")
    static let remote = Speaker(id: "SPEAKER_REMOTE", source: .systemAudio, label: "Remote")
}
