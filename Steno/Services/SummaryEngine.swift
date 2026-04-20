import Foundation
import LLM
import os

@MainActor
final class SummaryEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Float)
        case loading
        case generating
        case complete
        case error(String)
    }

    enum SummaryModel: String, CaseIterable, Identifiable {
        case qwen3_4b = "qwen3_4b"
        case gemma2_2b = "gemma2_2b"
        case phi3_mini = "phi3_mini"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .qwen3_4b: "Qwen 3 4B — Recommended"
            case .gemma2_2b: "Gemma 2 2B — Lightweight"
            case .phi3_mini: "Phi 3 Mini — Balanced"
            }
        }

        var size: String {
            switch self {
            case .qwen3_4b: "~2.5 GB"
            case .gemma2_2b: "~1.5 GB"
            case .phi3_mini: "~2.2 GB"
            }
        }

        var huggingFaceID: String {
            switch self {
            case .qwen3_4b: "Qwen/Qwen3-4B-GGUF"
            case .gemma2_2b: "bartowski/gemma-2-2b-it-GGUF"
            case .phi3_mini: "bartowski/Phi-3.5-mini-instruct-GGUF"
            }
        }

        var fileName: String {
            switch self {
            case .qwen3_4b: "Qwen3-4B-Q4_K_M.gguf"
            case .gemma2_2b: "gemma-2-2b-it-Q4_K_M.gguf"
            case .phi3_mini: "Phi-3.5-mini-instruct-Q4_K_M.gguf"
            }
        }

        var template: Template {
            switch self {
            case .qwen3_4b: .chatML("You are a helpful meeting summarizer.")
            case .gemma2_2b: .gemma
            case .phi3_mini: .chatML("You are a helpful meeting summarizer.")
            }
        }
    }

    @Published var state: State = .idle
    @Published var lastSummary: String?
    @Published var generationInfo: String?
    @Published var selectedModel: SummaryModel {
        didSet {
            if oldValue != selectedModel {
                bot = nil
                UserDefaults.standard.set(selectedModel.rawValue, forKey: "summaryModel")
            }
        }
    }

    private var bot: LLM?
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "SummaryEngine")

    static var currentModelID: String {
        let saved = UserDefaults.standard.string(forKey: "summaryModel") ?? SummaryModel.qwen3_4b.rawValue
        return SummaryModel(rawValue: saved)?.huggingFaceID ?? SummaryModel.qwen3_4b.huggingFaceID
    }

    var isModelReady: Bool { bot != nil }

    init() {
        let saved = UserDefaults.standard.string(forKey: "summaryModel") ?? SummaryModel.qwen3_4b.rawValue
        self.selectedModel = SummaryModel(rawValue: saved) ?? .qwen3_4b
    }

    func loadModel() async {
        guard bot == nil else { return }
        state = .loading
        logger.info("Loading summary model: \(self.selectedModel.huggingFaceID)")

        do {
            let model = selectedModel
            let hfModel = HuggingFaceModel(model.huggingFaceID, .Q4_K_M, template: model.template)
            let loadedBot = try await LLM(
                from: hfModel,
                maxTokenCount: 4096
            ) { [weak self] progress in
                Task { @MainActor in
                    if progress >= 1.0 {
                        self?.state = .loading
                    } else {
                        self?.state = .downloading(Float(progress))
                    }
                }
            }
            guard let loadedBot else {
                state = .error("Failed to initialize model.")
                return
            }

            bot = loadedBot
            state = .idle
            logger.info("Summary model loaded")
            Analytics.summaryModelDownloaded(model: selectedModel.huggingFaceID)
        } catch {
            state = .error("Failed to load summary model. Check your internet connection.")
            logger.error("Failed to load summary model: \(error)")
        }
    }

    /// Max chars per chunk prompt.
    private static let maxChunkChars = 20000

    @discardableResult
    func summarize(
        transcript: Transcript,
        instruction: String = SummaryPreset.fullSummary.instruction,
        context: String? = nil
    ) async -> String? {
        if bot == nil {
            await loadModel()
        }
        guard bot != nil else { return nil }

        state = .generating
        lastSummary = nil
        generationInfo = nil
        let startTime = Date()

        let chunks = chunkTranscript(transcript)
        let prompt: String

        if chunks.count == 1 {
            prompt = buildPrompt(
                transcript: transcript, instruction: instruction, context: context)
        } else {
            logger.info("Chunked summarization: \(chunks.count) chunks")
            var chunkSummaries: [String] = []

            for (i, chunk) in chunks.enumerated() {
                logger.info("Summarizing chunk \(i + 1)/\(chunks.count)")
                let chunkPrompt = buildChunkPrompt(
                    segments: chunk, transcript: transcript, context: context)

                if let result = await generateText(bot: bot!, prompt: chunkPrompt) {
                    chunkSummaries.append(result)
                }
            }

            guard !chunkSummaries.isEmpty else {
                state = .error("Failed to summarize transcript chunks")
                return nil
            }

            prompt = buildCombinePrompt(
                chunkSummaries: chunkSummaries, instruction: instruction, context: context,
                transcript: transcript)
        }

        guard let finalText = await generateText(bot: bot!, prompt: prompt),
              !finalText.isEmpty else {
            state = .error("Summary generation produced no output. Try a different model in Settings.")
            return nil
        }

        let elapsed = Date().timeIntervalSince(startTime)
        generationInfo = String(format: "Generated in %.1fs", elapsed)
        let transcriptMins = Int(transcript.durationSeconds / 60)
        Analytics.summaryGenerated(
            model: selectedModel.huggingFaceID,
            durationSeconds: elapsed,
            transcriptMinutes: transcriptMins,
            presetName: nil
        )

        lastSummary = finalText
        state = .complete
        return finalText
    }

    private func generateText(bot: sending LLM, prompt: String) async -> String? {
        let result = await bot.getCompletion(from: prompt)
        guard !result.isEmpty, result != "LLM is being used" else { return nil }
        let cleaned = Self.stripThinkingTags(result)
        if cleaned.isEmpty && !result.isEmpty {
            logger.info("Output was entirely think tags, returning raw")
            return result
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Strip `<think>...</think>` reasoning blocks.
    private static func stripThinkingTags(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        if let regex = try? NSRegularExpression(pattern: "<think>[\\s\\S]*$", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Chunking

    private func chunkTranscript(_ transcript: Transcript) -> [[Transcript.Segment]] {
        var chunks: [[Transcript.Segment]] = []
        var currentChunk: [Transcript.Segment] = []
        var currentChars = 0

        for segment in transcript.segments {
            let segmentChars = segment.text.count + 20
            if currentChars + segmentChars > Self.maxChunkChars && !currentChunk.isEmpty {
                chunks.append(currentChunk)
                currentChunk = []
                currentChars = 0
            }
            currentChunk.append(segment)
            currentChars += segmentChars
        }
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }
        return chunks
    }

    private func buildChunkPrompt(
        segments: [Transcript.Segment], transcript: Transcript, context: String?
    ) -> String {
        let speakerLabels = buildSpeakerLabels(transcript: transcript)
        let hasSpeakers = segments.contains { $0.speaker != nil }

        var prompt = "Summarize this section of a meeting transcript.\n"
        prompt += "Capture key points, decisions, action items, and important details.\n"
        prompt += "Do not mention section numbers or that this is a partial transcript.\n\n"

        if let context, !context.isEmpty {
            prompt += "Context: \(context)\n\n"
        }

        prompt += "Transcript:\n"
        prompt += formatSegments(segments, speakerLabels: speakerLabels, hasSpeakers: hasSpeakers)
        return prompt
    }

    private func buildCombinePrompt(
        chunkSummaries: [String], instruction: String, context: String?,
        transcript: Transcript
    ) -> String {
        let durationMins = Int(transcript.durationSeconds / 60)

        var prompt = "You have notes from different parts of a meeting.\n"
        prompt += "Meeting duration: \(durationMins) minutes.\n\n"
        prompt += instruction + "\n\n"

        if let context, !context.isEmpty {
            prompt += "Context: \(context)\n\n"
        }

        prompt += "Notes from the meeting:\n\n"
        for summary in chunkSummaries {
            prompt += summary + "\n\n"
        }

        prompt += "Write a single, clean summary. Do not reference sections, parts, or notes. Write as if you attended the entire meeting."
        return prompt
    }

    // MARK: - Prompt Building

    private func buildPrompt(
        transcript: Transcript, instruction: String, context: String?
    ) -> String {
        let hasSpeakers = transcript.segments.contains { $0.speaker != nil }
        let speakerLabels = buildSpeakerLabels(transcript: transcript)

        var prompt = "You are summarizing a meeting transcript with timestamps.\n"
        if hasSpeakers {
            let names = speakerLabels.values.sorted().joined(separator: ", ")
            prompt += "Participants: \(names).\n"
        } else {
            prompt += "Speaker identification is not available.\n"
        }
        let durationMins = Int(transcript.durationSeconds / 60)
        prompt += "Meeting duration: \(durationMins) minutes.\n\n"
        prompt += instruction + "\n\n"

        if let context, !context.isEmpty {
            prompt += "Context: \(context)\n\n"
        }

        prompt += "Transcript:\n"
        prompt += formatSegments(transcript.segments, speakerLabels: speakerLabels, hasSpeakers: hasSpeakers)
        return prompt
    }

    // MARK: - Helpers

    private func buildSpeakerLabels(transcript: Transcript) -> [String: String] {
        var labels: [String: String] = [:]
        let speakerIDs = Set(transcript.segments.compactMap(\.speaker))
        for id in speakerIDs {
            if let speaker = transcript.speakers?[id] {
                labels[id] = speaker.label
            } else {
                let num = (Int(id.replacingOccurrences(of: "SPEAKER_", with: "")) ?? 0) + 1
                labels[id] = "Speaker \(num)"
            }
        }
        return labels
    }

    private func formatSegments(
        _ segments: [Transcript.Segment], speakerLabels: [String: String], hasSpeakers: Bool
    ) -> String {
        var text = ""
        for segment in segments {
            let mins = Int(segment.start) / 60
            let secs = Int(segment.start) % 60
            let ts = String(format: "%02d:%02d", mins, secs)
            if hasSpeakers, let speakerID = segment.speaker, let name = speakerLabels[speakerID] {
                text += "[\(ts)] \(name): \(segment.text)\n"
            } else {
                text += "[\(ts)] \(segment.text)\n"
            }
        }
        return text
    }
}
