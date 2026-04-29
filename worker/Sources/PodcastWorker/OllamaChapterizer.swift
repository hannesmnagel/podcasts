import Foundation

struct OllamaChapterizer {
    let baseURL: URL
    let model: String
    let minimumSpacing: TimeInterval
    let maximumChapters: Int

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func chapters(for episode: EpisodeDTO, segments: [TranscriptSegment]) async throws -> [ChapterDTO] {
        let orderedSegments = segments.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
        let transcript = fullTranscript(from: orderedSegments)
        let prompt = """
        You chapterize podcast transcripts. Return only JSON that validates against the requested schema.
        The root object must have exactly one key named chapters.
        Do not return context, type, metadata, summaries, explanations, markdown, or any keys other than chapters.

        Exact example:
        {"chapters":[{"title":"Introduction","startAnchor":"Welcome to the show","endAnchor":"our first topic"},{"title":"Artemis Mission Update","startAnchor":"NASA announced","endAnchor":"that wraps up Artemis"}]}

        Rules:
        - Use between 2 and \(max(2, maximumChapters)) chapters.
        - Do not calculate or return timestamps.
        - For each chapter, copy startAnchor and endAnchor as exact short phrases from the transcript.
        - startAnchor is the transcript phrase where that chapter begins.
        - endAnchor is the transcript phrase where that chapter ends or transitions.
        - The first chapter must use a phrase from the beginning of the transcript.
        - Titles must be short, specific, and based on the transcript.
        - Do not invent facts that are not in the transcript.

        Episode title: \(episode.title)

        Full transcript with timestamps:
        \(transcript)
        """

        let response = try await generate(prompt: prompt)
        do {
            let chapters = try parseChapters(from: response, episode: episode, segments: orderedSegments)
            guard chapters.count > 1 else { throw WorkerError.chapterizationFailed }
            return chapters
        } catch {
            print("  Ollama returned unusable chapter anchors; retrying once")
            let retryResponse = try await generate(prompt: retryPrompt(originalPrompt: prompt, invalidResponse: response))
            let chapters = try parseChapters(from: retryResponse, episode: episode, segments: orderedSegments)
            print("  Ollama retry produced \(chapters.count) usable chapter(s)")
            return chapters
        }
    }

    private func generate(prompt: String) async throws -> String {
        let requestBody = OllamaGenerateRequest(
            model: model,
            prompt: prompt,
            stream: false,
            format: .chapterSchema,
            options: OllamaGenerateOptions(temperature: 0.1, numPredict: 1_600, numCtx: 65_536)
        )
        var request = URLRequest(url: URL(string: "api/generate", relativeTo: baseURL)!.absoluteURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WorkerError.ollamaInvalidResponse("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WorkerError.ollamaInvalidResponse("HTTP \(http.statusCode): \(String(decoding: data.prefix(1_000), as: UTF8.self))")
        }
        do {
            return try decoder.decode(OllamaGenerateResponse.self, from: data).response
        } catch {
            throw WorkerError.ollamaInvalidResponse("could not decode /api/generate response: \(error). Body: \(String(decoding: data.prefix(1_000), as: UTF8.self))")
        }
    }

    private func retryPrompt(originalPrompt: String, invalidResponse: String) -> String {
        """
        Your previous response was invalid for this task.

        Invalid response:
        \(invalidResponse)

        Fix it by returning only this JSON shape and nothing else:
        {"chapters":[{"title":"Introduction","startAnchor":"exact copied phrase","endAnchor":"exact copied phrase"},{"title":"Specific Topic","startAnchor":"exact copied phrase","endAnchor":"exact copied phrase"}]}

        Every anchor must be copied from the transcript text, not invented. Do not return timestamps.

        Original task:
        \(originalPrompt)
        """
    }

    func parseChapters(from response: String, episode: EpisodeDTO, segments: [TranscriptSegment]) throws -> [ChapterDTO] {
        guard let data = jsonPayload(from: response).data(using: .utf8) else {
            throw WorkerError.ollamaInvalidResponse("response was not UTF-8")
        }
        let decoded: OllamaChapterResponse
        do {
            decoded = try decoder.decode(OllamaChapterResponse.self, from: data)
        } catch {
            do {
                decoded = OllamaChapterResponse(chapters: try decoder.decode([OllamaChapterAnchor].self, from: data))
            } catch {
                throw WorkerError.ollamaInvalidResponse("could not decode chapter anchors: \(error). Body: \(String(decoding: data.prefix(1_000), as: UTF8.self))")
            }
        }

        var chapters = decoded.chapters.compactMap { chapter -> ChapterDTO? in
            let title = chapter.title.trimmedTitle
            guard !title.isEmpty else { return nil }
            guard let start = startTime(for: chapter.startAnchor, in: segments) else { return nil }
            return ChapterDTO(start: floor(start), title: title)
        }
        .sorted { $0.start < $1.start }

        if chapters.first?.start != 0 {
            chapters.insert(ChapterDTO(start: 0, title: episode.title.trimmedTitle), at: 0)
        }

        let result = chapters
            .deduplicatedBySpacing(minimumSpacing)
            .prefix(maximumChapters)
            .map { $0 }
        print("  Ollama raw anchors: \(decoded.chapters.count), usable chapters after anchor matching: \(result.count)")
        return result
    }

    private func startTime(for anchor: String, in segments: [TranscriptSegment]) -> TimeInterval? {
        let normalizedAnchor = anchor.normalizedWords
        guard !normalizedAnchor.isEmpty else { return nil }

        if let exact = segments.first(where: { $0.text.normalizedWords.contains(normalizedAnchor) }) {
            return exact.start
        }

        let anchorWords = Set(normalizedAnchor.split(separator: " ").map(String.init))
        guard anchorWords.count >= 3 else { return nil }
        return segments
            .compactMap { segment -> (score: Double, start: TimeInterval)? in
                guard let start = segment.start else { return nil }
                let words = Set(segment.text.normalizedWords.split(separator: " ").map(String.init))
                guard !words.isEmpty else { return nil }
                let overlap = anchorWords.intersection(words).count
                let score = Double(overlap) / Double(anchorWords.count)
                return (score, start)
            }
            .filter { $0.score >= 0.55 }
            .max { $0.score < $1.score }?
            .start
    }

    private func jsonPayload(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return trimmed
        }
        guard let start = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let end = trimmed.lastIndex(where: { $0 == "}" || $0 == "]" }),
              start <= end else {
            return trimmed
        }
        return String(trimmed[start...end])
    }

    private func fullTranscript(from segments: [TranscriptSegment]) -> String {
        segments
            .map { segment in
                let start = Int(segment.start ?? 0)
                return "[\(start)s] \(segment.text.singleLine)"
            }
            .joined(separator: "\n")
    }
}

private struct OllamaGenerateRequest: Encodable {
    let model: String
    let prompt: String
    let stream: Bool
    let format: OllamaFormat
    let options: OllamaGenerateOptions
}

private struct OllamaFormat: Encodable {
    static let chapterSchema = OllamaFormat()

    func encode(to encoder: any Encoder) throws {
        var root = encoder.container(keyedBy: SchemaKey.self)
        try root.encode("object", forKey: SchemaKey("type"))
        try root.encode(["chapters"], forKey: SchemaKey("required"))
        try root.encode(false, forKey: SchemaKey("additionalProperties"))

        var properties = root.nestedContainer(keyedBy: SchemaKey.self, forKey: SchemaKey("properties"))
        var chapters = properties.nestedContainer(keyedBy: SchemaKey.self, forKey: SchemaKey("chapters"))
        try chapters.encode("array", forKey: SchemaKey("type"))

        var item = chapters.nestedContainer(keyedBy: SchemaKey.self, forKey: SchemaKey("items"))
        try item.encode("object", forKey: SchemaKey("type"))
        try item.encode(["title", "startAnchor", "endAnchor"], forKey: SchemaKey("required"))
        try item.encode(false, forKey: SchemaKey("additionalProperties"))

        var chapterProperties = item.nestedContainer(keyedBy: SchemaKey.self, forKey: SchemaKey("properties"))
        var title = chapterProperties.nestedContainer(keyedBy: SchemaKey.self, forKey: SchemaKey("title"))
        try title.encode("string", forKey: SchemaKey("type"))
        var startAnchor = chapterProperties.nestedContainer(keyedBy: SchemaKey.self, forKey: SchemaKey("startAnchor"))
        try startAnchor.encode("string", forKey: SchemaKey("type"))
        var endAnchor = chapterProperties.nestedContainer(keyedBy: SchemaKey.self, forKey: SchemaKey("endAnchor"))
        try endAnchor.encode("string", forKey: SchemaKey("type"))
    }
}

private struct SchemaKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private struct OllamaGenerateOptions: Encodable {
    let temperature: Double
    let numPredict: Int
    let numCtx: Int

    enum CodingKeys: String, CodingKey {
        case temperature
        case numPredict = "num_predict"
        case numCtx = "num_ctx"
    }
}

private struct OllamaGenerateResponse: Decodable {
    let response: String
}

private struct OllamaChapterResponse: Decodable {
    let chapters: [OllamaChapterAnchor]
}

private struct OllamaChapterAnchor: Decodable {
    let title: String
    let startAnchor: String
    let endAnchor: String
}

private extension Array where Element == ChapterDTO {
    func deduplicatedBySpacing(_ minimumSpacing: TimeInterval) -> [ChapterDTO] {
        var result: [ChapterDTO] = []
        for chapter in self where result.last.map({ chapter.start - $0.start >= minimumSpacing }) ?? true {
            result.append(chapter)
        }
        return result
    }
}

private extension String {
    var singleLine: String {
        replacing("\n", with: " ")
            .replacing("\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedTitle: String {
        singleLine.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    var normalizedWords: String {
        lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
