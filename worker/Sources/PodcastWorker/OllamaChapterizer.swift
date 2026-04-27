import Foundation

struct OllamaChapterizer {
    let baseURL: URL
    let model: String
    let minimumSpacing: TimeInterval
    let maximumChapters: Int

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func chapters(for episode: EpisodeDTO, segments: [TranscriptSegment]) async throws -> [ChapterDTO] {
        let duration = episode.duration ?? segments.compactMap(\.end).max() ?? 0
        let transcript = transcriptExcerpt(from: segments)
        let prompt = """
        You chapterize podcast transcripts. Return only JSON, with this exact shape:
        {"chapters":[{"start":0,"title":"Introduction"}]}

        Rules:
        - Use \(max(2, maximumChapters)) or fewer chapters.
        - Every start must be a number of seconds from the beginning.
        - The first chapter must start at 0.
        - Chapter starts must be at least \(Int(minimumSpacing)) seconds apart.
        - Titles must be short, specific, and based on the transcript.
        - Do not invent facts that are not in the transcript.

        Episode title: \(episode.title)
        Duration seconds: \(Int(duration))

        Transcript with timestamps:
        \(transcript)
        """

        let response = try await generate(prompt: prompt)
        return try parseChapters(from: response, episode: episode, duration: duration)
    }

    private func generate(prompt: String) async throws -> String {
        let requestBody = OllamaGenerateRequest(
            model: model,
            prompt: prompt,
            stream: false,
            format: "json",
            options: OllamaGenerateOptions(temperature: 0.1, numPredict: 1_200)
        )
        var request = URLRequest(url: URL(string: "api/generate", relativeTo: baseURL)!.absoluteURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WorkerError.ollamaInvalidResponse
        }
        return try decoder.decode(OllamaGenerateResponse.self, from: data).response
    }

    func parseChapters(from response: String, episode: EpisodeDTO, duration: TimeInterval) throws -> [ChapterDTO] {
        guard let data = response.data(using: .utf8) else { throw WorkerError.ollamaInvalidResponse }
        let decoded = try decoder.decode(OllamaChapterResponse.self, from: data)
        var chapters = decoded.chapters
            .compactMap { chapter -> ChapterDTO? in
                let title = chapter.title.trimmedTitle
                guard !title.isEmpty else { return nil }
                guard chapter.start >= 0 else { return nil }
                guard duration <= 0 || chapter.start <= duration else { return nil }
                return ChapterDTO(start: floor(chapter.start), title: title)
            }
            .sorted { $0.start < $1.start }

        if chapters.first?.start != 0 {
            chapters.insert(ChapterDTO(start: 0, title: episode.title.trimmedTitle), at: 0)
        }

        return chapters
            .deduplicatedBySpacing(minimumSpacing)
            .prefix(maximumChapters)
            .map { $0 }
    }

    private func transcriptExcerpt(from segments: [TranscriptSegment]) -> String {
        segments
            .sorted { ($0.start ?? 0) < ($1.start ?? 0) }
            .map { segment in
                let start = Int(segment.start ?? 0)
                return "[\(start)s] \(segment.text.singleLine)"
            }
            .joined(separator: "\n")
            .prefix(18_000)
            .description
    }
}

private struct OllamaGenerateRequest: Encodable {
    let model: String
    let prompt: String
    let stream: Bool
    let format: String
    let options: OllamaGenerateOptions
}

private struct OllamaGenerateOptions: Encodable {
    let temperature: Double
    let numPredict: Int

    enum CodingKeys: String, CodingKey {
        case temperature
        case numPredict = "num_predict"
    }
}

private struct OllamaGenerateResponse: Decodable {
    let response: String
}

private struct OllamaChapterResponse: Decodable {
    let chapters: [OllamaChapter]
}

private struct OllamaChapter: Decodable {
    let start: TimeInterval
    let title: String
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
}
