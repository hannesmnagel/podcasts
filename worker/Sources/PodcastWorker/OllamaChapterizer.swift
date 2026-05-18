import Foundation

struct OllamaChapterizer {
    let baseURL: URL
    let model: String
    let minimumSpacing: TimeInterval
    let maximumChapters: Int
    var contextWindow = 65_536
    var logRawResponses = false

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func chapters(for episode: EpisodeDTO, segments: [TranscriptSegment]) async throws -> [ChapterDTO] {
        let orderedSegments = segments.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
        let duration = episode.duration ?? orderedSegments.compactMap(\.end).max() ?? orderedSegments.compactMap(\.start).max() ?? 0
        let transcript = chapterizationTranscript(from: orderedSegments)
        if transcript.count > 60_000 || duration > 5_400 {
            let chapters = try await sectionedChapters(for: episode, segments: orderedSegments, duration: duration)
            guard chapters.count > 1 else { throw WorkerError.chapterizationFailed }
            return chapters
        }
        let targetChapters = targetChapterCount(for: duration)
        let summary = episode.summary?.singleLine.nilIfEmpty ?? "No episode summary was provided."
        let prompt = """
        You chapterize podcast transcripts into listener-friendly podcast chapters. Return only JSON that validates against the requested schema.
        The root object must have exactly one key named chapters.
        Do not return context, type, metadata, summaries, explanations, markdown, or any keys other than chapters.

        Rules:
        - Use about \(targetChapters) chapters, never fewer than 2 and never more than \(max(2, maximumChapters)).
        - Prefer real show segments: intro, named recurring segments, interviews, news items, listener questions, games, wrap-up, and clearly new main topics.
        - For shows with many topics, create one chapter per meaningful topic instead of one huge "News" chapter.
        - Do not create chapters for brief tangents, sentence-level subpoints, or ads unless the ad/read is a long distinct segment.
        - startSecond must be copied from the first number in a bracketed transcript window, as a number of seconds.
        - The first chapter must use a phrase from the beginning of the transcript.
        - Titles must be short, specific, title-cased, and based on the transcript.
        - Do not use generic titles like Topic 1, Discussion, News Item, or Segment unless the transcript itself names that segment.
        - Do not invent facts that are not in the transcript.

        Episode title: \(episode.title)
        Episode summary/show notes: \(summary)

        Transcript windows with timestamps:
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

    private func sectionedChapters(for episode: EpisodeDTO, segments: [TranscriptSegment], duration: TimeInterval) async throws -> [ChapterDTO] {
        let windows = chapterizationWindows(from: segments.filter { !$0.text.singleLine.isEmpty })
        let sections = transcriptSections(from: windows)
        let totalTarget = targetChapterCount(for: duration)
        let summary = episode.summary?.singleLine.nilIfEmpty ?? "No episode summary was provided."
        let inventory = summaryInventory(from: episode.summary)
        var allChapters: [ChapterDTO] = []

        print("  chapterizing in \(sections.count) full-text section(s)")
        for (index, section) in sections.enumerated() {
            let sectionDuration = max(1, (section.last?.end ?? section.first?.start ?? 0) - (section.first?.start ?? 0))
            let sectionTarget = min(6, max(3, Int(ceil(Double(totalTarget) * sectionDuration / max(duration, 1))) + 2))
            let sectionTranscript = transcriptLines(from: section)
            let prompt = """
            You chapterize one excerpt from a longer podcast transcript. Return only JSON that validates against the schema.
            The root object must have exactly one key named chapters.

            Rules:
            - Return 0 to \(sectionTarget + 1) chapters that begin inside this excerpt.
            - Include only major topic or recurring-segment starts, not minor subpoints.
            - Use the episode summary/show notes as the expected inventory of major segments when possible.
            - If a show-note inventory item begins in this excerpt, create at most one chapter for that item.
            - Title that chapter using the show-note item wording unless the transcript gives a clearer title.
            - If this excerpt starts at the beginning of the episode, use "Introduction" for the opening chapter; do not label the opening as a later topic.
            - For recurring games or segments, choose the segment start, not individual items inside the game.
            - startSecond must be copied from the first number in a bracketed transcript window.
            - Titles must be short, specific, title-cased, and based on the transcript.
            - Do not invent facts.

            Episode title: \(episode.title)
            Episode summary/show notes: \(summary)
            Expected major segments:
            \(inventory)
            Excerpt \(index + 1) of \(sections.count):
            \(sectionTranscript)
            """
            let response = try await generate(prompt: prompt)
            logRawResponse(response, label: "section \(index + 1)")
            let chapters = try parseChapters(from: response, episode: episode, segments: segments, insertIntro: false)
            print("  section \(index + 1)/\(sections.count): \(chapters.count) chapter candidate(s)")
            allChapters.append(contentsOf: chapters)
        }

        var candidates = deduplicate(
            allChapters.sorted { $0.start < $1.start },
            inventoryItems: inventoryItems(from: episode.summary)
        )
        if candidates.first?.start != 0 {
            candidates.insert(ChapterDTO(start: 0, title: episode.title.trimmedTitle), at: 0)
        }

        let result: [ChapterDTO]
        if candidates.count > max(4, totalTarget / 2) {
            let selected = try await selectFinalChapters(from: candidates, episode: episode, targetCount: totalTarget)
            let inventorySelected = inventoryConstrainedSelection(from: candidates, episode: episode)
            if inventorySelected.count >= max(6, selected.count - 1) {
                print("  inventory-constrained selection kept \(inventorySelected.count) chapter(s)")
                result = inventorySelected
            } else {
                result = selected
            }
        } else {
            result = candidates
                .prefix(maximumChapters)
                .map { $0 }
        }
        print("  sectioned chapterization produced \(result.count) usable chapter(s)")
        return result
    }

    private func selectFinalChapters(from candidates: [ChapterDTO], episode: EpisodeDTO, targetCount: Int) async throws -> [ChapterDTO] {
        let candidateLines = candidates
            .enumerated()
            .map { "C\($0.offset): [\(Int($0.element.start))s] \($0.element.title)" }
            .joined(separator: "\n")
        let summary = episode.summary?.singleLine.nilIfEmpty ?? "No episode summary was provided."
        let inventory = summaryInventory(from: episode.summary)
        let prompt = """
        You are selecting the final podcast chapters from LLM-generated chapter candidates.
        Return only JSON that validates against the schema.
        The root object must have exactly one key named chapters.

        Rules:
        - Choose the best final chapters from the candidates, usually \(min(candidates.count, targetCount)) or fewer if the extra candidates are subtopics or duplicates, never more than \(maximumChapters).
        - The expected major segments list is authoritative.
        - Every final chapter after Introduction should correspond to one expected major segment.
        - Preserve major topic or recurring-segment starts, not internal details.
        - Remove duplicate chapters and subtopics that are inside the same larger discussion.
        - Keep at most one chapter per show-note inventory item.
        - Prefer the earliest candidate for a topic if several candidates describe the same topic.
        - Include candidates that directly match expected major segments, especially recurring segments.
        - Prefer candidates whose titles match show-note inventory items.
        - Do not keep candidates that are narrower subtopics of a show-note inventory item when a broader candidate exists.
        - Keep recurring segment/game starts such as listener questions, noisy segments, and science-or-fiction as whole chapters; do not choose individual game items as separate chapters.
        - If a candidate at 0s is not an introduction/opening chapter, rename it to Introduction or choose a later candidate for that topic.
        - You must copy each chosen candidate's startSecond and title exactly.
        - Do not rename candidates.
        - Do not invent topics.

        Episode title: \(episode.title)
        Episode summary/show notes: \(summary)
        Expected major segments:
        \(inventory)

        Candidate chapters:
        \(candidateLines)
        """
        let response = try await generate(prompt: prompt)
        logRawResponse(response, label: "final selection")
        let selected = try parseFinalSelection(from: response, candidates: candidates, episode: episode)
        print("  final selection kept \(selected.count) chapter(s) from \(candidates.count) candidates")
        return selected
    }

    private func parseFinalSelection(from response: String, candidates: [ChapterDTO], episode: EpisodeDTO) throws -> [ChapterDTO] {
        guard let data = jsonPayload(from: response).data(using: .utf8) else {
            throw WorkerError.ollamaInvalidResponse("response was not UTF-8")
        }
        let decoded = try decoder.decode(OllamaChapterResponse.self, from: data)
        let candidatesByStart = Dictionary(grouping: candidates, by: { floor($0.start) })
        var selected: [ChapterDTO] = []
        for chapter in decoded.chapters {
            guard let start = chapter.startSecond.map(floor),
                  let match = candidatesByStart[start]?.first else { continue }
            selected.append(match)
        }
        if selected.first?.start != 0, let intro = candidates.first(where: { $0.start == 0 }) {
            selected.insert(intro, at: 0)
        }
        return deduplicate(
            selected.sorted { $0.start < $1.start },
            inventoryItems: inventoryItems(from: episode.summary)
        )
            .prefix(maximumChapters)
            .map { $0 }
    }

    private func summaryInventory(from summary: String?) -> String {
        let items = inventoryItems(from: summary)
        guard !items.isEmpty else { return "- No show-note inventory provided." }
        return items.map { "- \($0)" }.joined(separator: "\n")
    }

    private func inventoryItems(from summary: String?) -> [String] {
        guard let summary = summary?.singleLine.nilIfEmpty else { return [] }
        let sections = summary.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return sections.flatMap { section -> [String] in
            let parts = section.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2 else { return [section] }
            let heading = parts[0]
            let children = parts[1].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return children.isEmpty ? [heading] : children.map { "\(heading): \($0)" }
        }
    }

    private func inventoryConstrainedSelection(from candidates: [ChapterDTO], episode: EpisodeDTO) -> [ChapterDTO] {
        let items = inventoryItems(from: episode.summary)
        guard items.count >= 3 else { return [] }

        var selected: [ChapterDTO] = []
        if let intro = candidates.first(where: { $0.start == 0 }) {
            selected.append(ChapterDTO(start: intro.start, title: "Introduction"))
        }

        var usedStarts = Set<Int>(selected.map { Int($0.start) })
        for item in items {
            let itemWords = groundingWords(for: item)
            guard !itemWords.isEmpty else { continue }
            let threshold = groundingThreshold(for: itemWords)
            guard let match = candidates.first(where: { candidate in
                guard usedStarts.contains(Int(candidate.start)) == false else { return false }
                let title = candidate.title.normalizedWords
                return groundingScore(for: itemWords, text: title) >= threshold
            }) else {
                continue
            }
            selected.append(match)
            usedStarts.insert(Int(match.start))
        }

        return deduplicate(
            selected.sorted { $0.start < $1.start },
            inventoryItems: items
        )
            .prefix(maximumChapters)
            .map { $0 }
    }

    private func generate(prompt: String) async throws -> String {
        let requestBody = OllamaGenerateRequest(
            model: model,
            prompt: prompt,
            stream: false,
            format: .chapterSchema,
            options: OllamaGenerateOptions(temperature: 0.1, numPredict: 2_400, numCtx: contextWindow)
        )
        var request = URLRequest(url: URL(string: "api/generate", relativeTo: baseURL)!.absoluteURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
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

    private func logRawResponse(_ response: String, label: String) {
        guard logRawResponses else { return }
        print("  raw \(label) response:")
        print(response)
    }

    private func retryPrompt(originalPrompt: String, invalidResponse: String) -> String {
        """
        Your previous response was invalid for this task.

        Your previous response could not be used because it was not valid JSON or did not follow the schema.

        Return only a valid JSON object with a chapters array. Every startSecond must be copied from a bracketed transcript timestamp.

        Original task:
        \(originalPrompt)
        """
    }

    func parseChapters(from response: String, episode: EpisodeDTO, segments: [TranscriptSegment], insertIntro: Bool = true) throws -> [ChapterDTO] {
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
            guard let start = startTime(for: chapter, in: segments) else { return nil }
            return ChapterDTO(start: floor(start), title: title)
        }
        .sorted { $0.start < $1.start }

        if !insertIntro {
            chapters = chapters.filter { chapter in
                if chapter.title.normalizedWords == "introduction", chapter.start > 60 { return false }
                return recurringSegmentCandidateIsValid(chapter, segments: segments)
                    && chapterTitleIsGrounded(chapter, segments: segments)
            }
        }

        if insertIntro, chapters.first?.start != 0 {
            chapters.insert(ChapterDTO(start: 0, title: episode.title.trimmedTitle), at: 0)
        }

        let result = deduplicate(
            chapters,
            inventoryItems: insertIntro ? [] : inventoryItems(from: episode.summary)
        )
            .prefix(maximumChapters)
            .map { $0 }
        print("  Ollama raw anchors: \(decoded.chapters.count), usable chapters after anchor matching: \(result.count)")
        return result
    }

    private func deduplicate(_ chapters: [ChapterDTO], inventoryItems: [String]) -> [ChapterDTO] {
        let ordered = chapters.sorted { $0.start < $1.start }
        var result: [ChapterDTO] = []
        var group: [ChapterDTO] = []

        func best(in group: [ChapterDTO]) -> ChapterDTO? {
            group.max { lhs, rhs in
                let lhsScore = inventoryScore(for: lhs, inventoryItems: inventoryItems)
                let rhsScore = inventoryScore(for: rhs, inventoryItems: inventoryItems)
                if lhsScore == rhsScore {
                    return lhs.start > rhs.start
                }
                return lhsScore < rhsScore
            }
        }

        func flushGroup() {
            guard let chapter = best(in: group) else { return }
            result.append(chapter)
            group = []
        }

        for chapter in ordered {
            if let first = group.first, chapter.start - first.start >= minimumSpacing {
                flushGroup()
            }
            group.append(chapter)
        }
        flushGroup()
        return result
    }

    private func inventoryScore(for chapter: ChapterDTO, inventoryItems: [String]) -> Int {
        guard !inventoryItems.isEmpty else { return 0 }
        let title = chapter.title.normalizedWords
        return inventoryItems.enumerated().reduce(0) { best, item in
            let words = groundingWords(for: item.element)
            guard !words.isEmpty else { return best }
            let score = groundingScore(for: words, text: title)
            guard score >= groundingThreshold(for: words) else { return best }
            return max(best, 1_000 + score - item.offset)
        }
    }

    private func recurringSegmentCandidateIsValid(_ chapter: ChapterDTO, segments: [TranscriptSegment]) -> Bool {
        let requiredPhrase = recurringPhrase(for: chapter.title)
        guard let requiredPhrase else { return true }
        return segments.contains { segment in
            guard let start = segment.start, abs(start - chapter.start) <= 180 else { return false }
            return segment.text.normalizedWords.contains(requiredPhrase)
        }
    }

    private func recurringPhrase(for title: String) -> String? {
        let title = title.normalizedWords
        if title.contains("science or fiction") {
            return "science or fiction"
        } else if title.contains("who s that noisy") || title.contains("whos that noisy") {
            return "who s that noisy"
        } else if title.contains("what s the word") || title.contains("whats the word") {
            return "what s the word"
        }
        return nil
    }

    private func chapterTitleIsGrounded(_ chapter: ChapterDTO, segments: [TranscriptSegment]) -> Bool {
        if chapter.start <= 60 { return true }
        let titleWords = groundingWords(for: chapter.title)
        guard !titleWords.isEmpty else { return true }
        let threshold = groundingThreshold(for: titleWords)

        let nearbyWords = Set(
            segments
                .filter { segment in
                    guard let start = segment.start else { return false }
                    return abs(start - chapter.start) <= 150
                }
                .flatMap { $0.text.normalizedWords.split(separator: " ").map { Self.normalizedToken(String($0)) } }
        )
        guard !nearbyWords.isEmpty else { return false }
        return titleWords.filter { nearbyWords.contains($0) }.count >= threshold
    }

    private func groundingWords(for title: String) -> [String] {
        var seen = Set<String>()
        return title.normalizedWords
            .split(separator: " ")
            .map(String.init)
            .map(Self.normalizedToken)
            .filter { Self.groundingStopWords.contains($0) == false && $0.count >= 4 }
            .filter { seen.insert($0).inserted }
    }

    private func groundingScore(for titleWords: [String], text: String) -> Int {
        let textWords = Set(text.split(separator: " ").map { Self.normalizedToken(String($0)) })
        return titleWords.filter { textWords.contains($0) }.count
    }

    private static func normalizedToken(_ token: String) -> String {
        guard token.count > 4, token.hasSuffix("s") else { return token }
        return String(token.dropLast())
    }

    private func groundingThreshold(for titleWords: [String]) -> Int {
        guard titleWords.count > 1 else { return 1 }
        return max(2, Int(ceil(Double(titleWords.count) * 0.5)))
    }

    private static let groundingStopWords: Set<String> = [
        "about", "after", "again", "also", "before", "being", "chapter",
        "discussion", "does", "emails", "episode", "follow", "from", "into", "item", "items",
        "listener", "mail", "main", "news", "podcast", "question", "questions", "segment",
        "seems", "show", "that", "their", "there", "this", "topic", "united", "updates", "what", "when", "where",
        "which", "while", "with", "word", "work", "works", "your"
    ]

    private func targetChapterCount(for duration: TimeInterval) -> Int {
        guard duration > 0 else { return min(maximumChapters, 8) }
        let minutes = duration / 60
        let target: Int
        switch minutes {
        case ..<20: target = 4
        case ..<45: target = 6
        case ..<75: target = 9
        case ..<120: target = 12
        default: target = 16
        }
        return min(max(2, target), maximumChapters)
    }

    private func startTime(for chapter: OllamaChapterAnchor, in segments: [TranscriptSegment]) -> TimeInterval? {
        if let startSecond = chapter.startSecond {
            if let grounded = groundedSegmentStart(for: chapter.title, proposedStart: startSecond, in: segments) {
                return grounded
            }
            if groundingWords(for: chapter.title).isEmpty,
               let snapped = nearestSegmentStart(to: startSecond, in: segments) {
                return snapped
            }
        }
        if let startAnchor = chapter.startAnchor,
           let start = startTime(for: startAnchor, in: segments) {
            return start
        }
        return nil
    }

    private func groundedSegmentStart(for title: String, proposedStart: TimeInterval, in segments: [TranscriptSegment]) -> TimeInterval? {
        if proposedStart <= 60 || title.normalizedWords == "introduction" {
            return nearestSegmentStart(to: proposedStart, in: segments)
        }
        let titleWords = groundingWords(for: title)
        guard !titleWords.isEmpty else {
            return nearestSegmentStart(to: proposedStart, in: segments)
        }
        let threshold = groundingThreshold(for: titleWords)
        if let phrase = recurringPhrase(for: title),
           let start = segments.first(where: { segment in
               guard let start = segment.start else { return false }
               return start >= proposedStart - 600
                   && start <= proposedStart + 180
                   && segment.text.normalizedWords.contains(phrase)
           })?.start {
            return start
        }
        for index in segments.indices {
            guard let start = segments[index].start,
                  start >= proposedStart - 600,
                  start <= proposedStart + 180 else { continue }
            let localSegments = segments[index..<min(index + 3, segments.endIndex)]
            let localText = localSegments
                .map(\.text.normalizedWords)
                .joined(separator: " ")
            if groundingScore(for: titleWords, text: localText) >= threshold {
                return localSegments.first { segment in
                    groundingScore(for: titleWords, text: segment.text.normalizedWords) > 0
                }?.start ?? start
            }
        }
        return nil
    }

    private func nearestSegmentStart(to startSecond: TimeInterval, in segments: [TranscriptSegment]) -> TimeInterval? {
        let starts = segments.compactMap(\.start)
        guard let nearest = starts.min(by: { abs($0 - startSecond) < abs($1 - startSecond) }) else { return nil }
        return abs(nearest - startSecond) <= 90 ? nearest : nil
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

    func chapterizationTranscript(from segments: [TranscriptSegment]) -> String {
        let validSegments = segments.filter { !$0.text.singleLine.isEmpty }
        guard validSegments.count > 350 else {
            return transcriptLines(from: validSegments)
        }

        return transcriptLines(from: chapterizationWindows(from: validSegments))
    }

    private func chapterizationWindows(from segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let pauseThreshold = relativePauseThreshold(for: segments)

        var windows: [TranscriptSegment] = []
        var windowStart: TimeInterval?
        var windowEnd: TimeInterval?
        var windowText: [String] = []
        var windowLength = 0
        var previousEnd: TimeInterval?

        func flushWindow() {
            guard let start = windowStart, !windowText.isEmpty else { return }
            windows.append(TranscriptSegment(start: start, end: windowEnd, text: windowText.joined(separator: " ")))
            windowStart = nil
            windowEnd = nil
            windowText = []
            windowLength = 0
        }

        for segment in segments {
            let start = segment.start ?? windowStart ?? 0
            let end = segment.end ?? start
            let text = segment.text.singleLine
            let currentDuration = start - (windowStart ?? start)
            let gap = previousEnd.map { max(0, start - $0) } ?? 0
            let isRelativePause = currentDuration >= 20 && gap >= pauseThreshold
            let isLargeEnough = currentDuration >= 90 || windowLength + text.count > 1_200
            if windowStart != nil, isRelativePause || isLargeEnough {
                flushWindow()
            }
            windowStart = windowStart ?? start
            windowEnd = end
            windowText.append(text)
            windowLength += text.count + 1
            previousEnd = end
        }
        flushWindow()
        return windows
    }

    private func transcriptSections(from windows: [TranscriptSegment]) -> [[TranscriptSegment]] {
        var sections: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var sectionStart: TimeInterval?
        var sectionLength = 0

        func flush() {
            guard !current.isEmpty else { return }
            sections.append(current)
            current = []
            sectionStart = nil
            sectionLength = 0
        }

        for window in windows {
            let start = window.start ?? sectionStart ?? 0
            let duration = start - (sectionStart ?? start)
            let length = window.text.count
            if !current.isEmpty, duration >= 720 || sectionLength + length > 14_000 {
                flush()
            }
            sectionStart = sectionStart ?? start
            current.append(window)
            sectionLength += length
        }
        flush()
        return sections
    }

    private func relativePauseThreshold(for segments: [TranscriptSegment]) -> TimeInterval {
        let gaps = zip(segments, segments.dropFirst()).compactMap { previous, current -> TimeInterval? in
            guard let previousEnd = previous.end, let currentStart = current.start else { return nil }
            let gap = currentStart - previousEnd
            return gap > 0.25 ? gap : nil
        }
        guard !gaps.isEmpty else { return 8 }

        let sorted = gaps.sorted()
        let median = sorted[sorted.count / 2]
        let p90 = sorted[Int(Double(sorted.count - 1) * 0.9)]
        return max(4, median * 4, p90 * 1.8)
    }

    private func transcriptLines(from segments: [TranscriptSegment]) -> String {
        segments.map { segment in
            let start = Int(segment.start ?? 0)
            let end = segment.end.map { "-\(Int($0))s" } ?? ""
            return "[\(start)s\(end)] \(segment.text.singleLine)"
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
        try item.encode(["title", "startSecond"], forKey: SchemaKey("required"))
        try item.encode(false, forKey: SchemaKey("additionalProperties"))

        var chapterProperties = item.nestedContainer(keyedBy: SchemaKey.self, forKey: SchemaKey("properties"))
        var title = chapterProperties.nestedContainer(keyedBy: SchemaKey.self, forKey: SchemaKey("title"))
        try title.encode("string", forKey: SchemaKey("type"))
        try title.encode(80, forKey: SchemaKey("maxLength"))
        var startSecond = chapterProperties.nestedContainer(keyedBy: SchemaKey.self, forKey: SchemaKey("startSecond"))
        try startSecond.encode("number", forKey: SchemaKey("type"))
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
    let startSecond: TimeInterval?
    let startAnchor: String?

    enum CodingKeys: String, CodingKey {
        case title
        case startSecond
        case startTime
        case start
        case startAnchor
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        startSecond = Self.decodeFlexibleTime(from: container, keys: [.startSecond, .startTime, .start])
        startAnchor = try container.decodeIfPresent(String.self, forKey: .startAnchor)
    }

    private static func decodeFlexibleTime(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> TimeInterval? {
        for key in keys {
            if let value = try? container.decodeIfPresent(TimeInterval.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }
}

private extension String {
    var singleLine: String {
        replacing("\n", with: " ")
            .replacing("\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
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
