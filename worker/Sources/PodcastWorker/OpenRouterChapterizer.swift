import Foundation

struct OpenRouterChapterizer {
    let apiKey: String
    let model: String
    let minimumSpacing: TimeInterval
    let maximumChapters: Int
    var contextWindow = 262_144
    var maxOutputTokens = 2_048
    var baseURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    func chapters(for episode: EpisodeDTO, segments: [TranscriptSegment]) async throws -> [ChapterDTO] {
        let orderedSegments = segments
            .filter { !$0.text.trimmedSingleLine.isEmpty }
            .sorted { ($0.start ?? 0) < ($1.start ?? 0) }
        guard !orderedSegments.isEmpty else { throw WorkerError.transcriptSegmentsMissing }

        let duration = episode.duration ?? orderedSegments.compactMap(\.end).max() ?? orderedSegments.compactMap(\.start).max() ?? 0
        let targetCount = targetChapterCount(for: duration)
        let transcript = try transcriptForPrompt(from: orderedSegments)
        let summaryText = episode.summary?.trimmedSingleLine ?? ""
        let summary = summaryText.isEmpty ? "No episode summary was provided." : summaryText

        let prompt = """
        You chapterize podcast transcripts into listener-friendly podcast chapters.
        You are receiving the entire transcript at once. Use the whole transcript, not excerpts.

        Return only a valid JSON object in this exact shape:
        {"chapters":[{"title":"Introduction","startSecond":0}]}

        Rules:
        - Use about \(targetCount) chapters; never fewer than 2 and never more than \(maximumChapters).
        - Chapters should represent real listener-level sections: intro, named recurring segments, interviews, news items, listener questions, games, wrap-up, and clearly new main topics.
        - Prefer one chapter per meaningful topic, not tiny subpoints.
        - Do not create chapters for brief tangents or ads unless an ad/read is a long distinct segment.
        - startSecond must be copied from the first number in a bracketed transcript window.
        - The first chapter must start at 0 or the first available transcript timestamp.
        - Titles must be short, specific, title-cased, and based on the transcript or show notes.
        - Do not invent facts that are not in the transcript.
        - Return JSON only. No markdown. No commentary.

        Episode title: \(episode.title)
        Episode summary/show notes: \(summary)

        Full transcript:
        \(transcript)
        """

        print("  sending transcript to OpenRouter model \(model) (\(transcript.count) chars, ~\(estimatedTokens(for: transcript)) tokens, context \(contextWindow))")
        let response = try await complete(prompt: prompt)
        let decoded = try decodeChapterResponse(response)
        let chapters = normalize(decoded.chapters, episode: episode, segments: orderedSegments)
        print("  OpenRouter returned \(decoded.chapters.count) raw chapter(s), \(chapters.count) usable")
        guard chapters.count > 1 else { throw WorkerError.chapterizationFailed }
        return chapters
    }

    private func complete(prompt: String) async throws -> String {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("The Podcatcher worker", forHTTPHeaderField: "X-Title")

        let body = OpenRouterChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: "You are a precise podcast chapterizer. Output strict JSON only."),
                .init(role: "user", content: prompt)
            ],
            temperature: 0.1,
            maxTokens: maxOutputTokens,
            reasoning: .init(effort: "none", exclude: true)
        )
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw WorkerError.openRouterFailed("HTTP \(http.statusCode): \(String(decoding: data.prefix(2_000), as: UTF8.self))")
        }
        let decoded: OpenRouterChatResponse
        do {
            decoded = try JSONDecoder().decode(OpenRouterChatResponse.self, from: data)
        } catch {
            throw WorkerError.openRouterFailed("could not decode OpenRouter envelope: \(error). Body: \(String(decoding: data.prefix(2_000), as: UTF8.self))")
        }
        if let error = decoded.error {
            throw WorkerError.openRouterFailed("provider error \(error.code.map(String.init) ?? "unknown"): \(error.message)")
        }
        if let usage = decoded.usage {
            print("  OpenRouter usage: prompt=\(usage.promptTokens ?? -1), completion=\(usage.completionTokens ?? -1), total=\(usage.totalTokens ?? -1)")
        }
        guard let content = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            let choice = decoded.choices.first
            let finish = choice?.finishReason ?? "nil"
            let nativeFinish = choice?.nativeFinishReason ?? "nil"
            let reasoningCount = choice?.message.reasoning?.count ?? 0
            throw WorkerError.openRouterFailed("empty content (finish_reason=\(finish), native_finish_reason=\(nativeFinish), reasoning_chars=\(reasoningCount), response_chars=\(data.count))")
        }
        return content
    }

    private func transcriptForPrompt(from segments: [TranscriptSegment]) throws -> String {
        let full = segments.map { segment in
            let start = Int((segment.start ?? 0).rounded())
            let end = Int((segment.end ?? segment.start ?? 0).rounded())
            return "[\(start)-\(end)] \(segment.text.trimmedSingleLine)"
        }.joined(separator: "\n")

        let maxInputTokens = contextWindow - maxOutputTokens - 1_500
        guard maxInputTokens >= 4_000 else {
            throw WorkerError.openRouterFailed("configured context is too small: context=\(contextWindow), max_output=\(maxOutputTokens)")
        }
        if estimatedTokens(for: full) <= maxInputTokens {
            return full
        }

        let maxCharacters = maxInputTokens * 4
        let compact = compactTranscript(from: segments, maxCharacters: maxCharacters)
        guard estimatedTokens(for: compact) <= maxInputTokens else {
            throw WorkerError.openRouterFailed("transcript exceeds configured context after compaction (~\(estimatedTokens(for: compact)) input tokens > \(maxInputTokens)); raise PODCAST_OPENROUTER_CONTEXT or use the sectioned Ollama path")
        }
        print("  compacted transcript for OpenRouter context (~\(estimatedTokens(for: full)) -> ~\(estimatedTokens(for: compact)) tokens)")
        return compact
    }

    private func compactTranscript(from segments: [TranscriptSegment], maxCharacters: Int) -> String {
        var lines: [String] = []
        var windowStart: TimeInterval?
        var windowEnd: TimeInterval?
        var text = ""
        let targetWindowCharacters = max(600, min(1_400, maxCharacters / 80))

        func flush() {
            guard let start = windowStart, !text.isEmpty else { return }
            let end = windowEnd ?? start
            lines.append("[\(Int(start.rounded()))-\(Int(end.rounded()))] \(text)")
            windowStart = nil
            windowEnd = nil
            text = ""
        }

        for segment in segments {
            let segmentText = segment.text.trimmedSingleLine
            guard !segmentText.isEmpty else { continue }
            if windowStart == nil { windowStart = segment.start ?? 0 }
            windowEnd = segment.end ?? segment.start ?? windowEnd
            if text.count + segmentText.count + 1 > targetWindowCharacters {
                flush()
                windowStart = segment.start ?? 0
                windowEnd = segment.end ?? segment.start
            }
            text += text.isEmpty ? segmentText : " \(segmentText)"
        }
        flush()
        return lines.joined(separator: "\n")
    }

    private func estimatedTokens(for text: String) -> Int {
        max(1, Int(ceil(Double(text.count) / 4.0)))
    }

    private func decodeChapterResponse(_ response: String) throws -> OpenRouterChapterResponse {
        let payload = jsonPayload(from: response)
        guard let data = payload.data(using: .utf8) else {
            throw WorkerError.openRouterFailed("response was not UTF-8")
        }
        do {
            return try JSONDecoder().decode(OpenRouterChapterResponse.self, from: data)
        } catch {
            throw WorkerError.openRouterFailed("could not decode chapter JSON: \(error). Body: \(String(decoding: data.prefix(1_000), as: UTF8.self))")
        }
    }

    private func jsonPayload(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines)
            return lines.dropFirst().dropLast().joined(separator: "\n")
        }
        guard let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last else {
            return trimmed
        }
        return String(trimmed[first...last])
    }

    private func normalize(_ rawChapters: [OpenRouterChapter], episode: EpisodeDTO, segments: [TranscriptSegment]) -> [ChapterDTO] {
        var seenStarts = Set<Int>()
        var normalized = rawChapters.compactMap { chapter -> ChapterDTO? in
            let title = chapter.title.trimmedChapterTitle
            guard !title.isEmpty, let proposedStart = chapter.startSecond else { return nil }
            let nearestStart = nearestSegmentStart(to: proposedStart, in: segments)
            let roundedStart = Int(nearestStart.rounded())
            guard seenStarts.insert(roundedStart).inserted else { return nil }
            return ChapterDTO(start: nearestStart, title: title)
        }
        .sorted { $0.start < $1.start }

        if normalized.first?.start ?? .infinity > 30 {
            normalized.insert(ChapterDTO(start: segments.first?.start ?? 0, title: "Introduction"), at: 0)
        }

        var deduped: [ChapterDTO] = []
        for chapter in normalized {
            if let previous = deduped.last, chapter.start - previous.start < minimumSpacing {
                continue
            }
            deduped.append(chapter)
            if deduped.count >= maximumChapters { break }
        }
        return deduped
    }

    private func nearestSegmentStart(to proposedStart: TimeInterval, in segments: [TranscriptSegment]) -> TimeInterval {
        segments.min { lhs, rhs in
            abs((lhs.start ?? 0) - proposedStart) < abs((rhs.start ?? 0) - proposedStart)
        }?.start ?? max(0, proposedStart)
    }

    private func targetChapterCount(for duration: TimeInterval) -> Int {
        guard duration > 0 else { return min(10, maximumChapters) }
        return min(maximumChapters, max(4, Int((duration / 600).rounded())))
    }
}

private struct OpenRouterChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double
    let maxTokens: Int
    let reasoning: Reasoning

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
        case reasoning
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct Reasoning: Encodable {
        let effort: String
        let exclude: Bool
    }
}

private struct OpenRouterChatResponse: Decodable {
    let choices: [Choice]
    let error: APIError?
    let usage: Usage?

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?
        let nativeFinishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
            case nativeFinishReason = "native_finish_reason"
        }
    }

    struct Message: Decodable {
        let content: String?
        let reasoning: String?

        enum CodingKeys: String, CodingKey {
            case content
            case reasoning
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let content = try? container.decodeIfPresent(String.self, forKey: .content) {
                self.content = content
            } else if let parts = try? container.decodeIfPresent([ContentPart].self, forKey: .content) {
                self.content = parts.compactMap(\.text).joined(separator: "\n")
            } else {
                self.content = nil
            }
            reasoning = try? container.decodeIfPresent(String.self, forKey: .reasoning)
        }
    }

    struct ContentPart: Decodable {
        let type: String?
        let text: String?
    }

    struct APIError: Decodable {
        let message: String
        let code: Int?
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

private struct OpenRouterChapterResponse: Decodable {
    let chapters: [OpenRouterChapter]
}

private struct OpenRouterChapter: Decodable {
    let title: String
    let startSecond: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case title
        case startSecond
        case startTime
        case start
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        startSecond = Self.decodeFlexibleTime(from: container, keys: [.startSecond, .startTime, .start])
    }

    private static func decodeFlexibleTime(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> TimeInterval? {
        for key in keys {
            if let value = try? container.decodeIfPresent(TimeInterval.self, forKey: key) { return value }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }
}

private extension String {
    var trimmedSingleLine: String {
        replacing("\n", with: " ")
            .replacing("\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedChapterTitle: String {
        trimmedSingleLine.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }
}
