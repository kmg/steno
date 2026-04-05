import Foundation
import WhisperKit

/// Steno's transcript format, wrapping WhisperKit segments with session metadata.
struct Transcript: Codable {
    var version: String = "1.0"
    var created: Date
    var durationSeconds: Double
    var model: String
    var speakers: [String: Speaker]?
    var segments: [Segment]

    struct Segment: Codable, Identifiable {
        var id: UUID
        var segmentIndex: Int
        var start: Float
        var end: Float
        var text: String
        var confidence: Float
        var language: String?
        var speaker: String?

        init(segmentIndex: Int, start: Float, end: Float, text: String, confidence: Float, language: String? = nil, speaker: String? = nil) {
            self.id = UUID()
            self.segmentIndex = segmentIndex
            self.start = start
            self.end = end
            self.text = text
            self.confidence = confidence
            self.language = language
            self.speaker = speaker
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
            self.segmentIndex = (try? container.decode(Int.self, forKey: .segmentIndex)) ?? 0
            self.start = try container.decode(Float.self, forKey: .start)
            self.end = try container.decode(Float.self, forKey: .end)
            self.text = try container.decode(String.self, forKey: .text)
            self.confidence = try container.decode(Float.self, forKey: .confidence)
            self.language = try container.decodeIfPresent(String.self, forKey: .language)
            self.speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
        }
    }

    /// Convert WhisperKit segments to Steno format, optionally with speaker labels.
    static func from(
        whisperSegments: [TranscriptionSegment],
        duration: Double,
        model: String,
        language: String?,
        speakerLabels: [String?]? = nil,
        speakers: [String: Speaker]? = nil
    ) -> Transcript {
        let segments = whisperSegments.enumerated().map { index, seg in
            Segment(
                segmentIndex: index,
                start: seg.start,
                end: seg.end,
                text: Self.cleanText(seg.text),
                confidence: 1.0 - seg.noSpeechProb,
                language: language,
                speaker: speakerLabels?[safe: index] ?? nil
            )
        }
        return Transcript(
            created: Date(),
            durationSeconds: duration,
            model: model,
            speakers: speakers,
            segments: segments
        )
    }

    /// Strip WhisperKit special tokens from segment text.
    private static func cleanText(_ text: String) -> String {
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

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
