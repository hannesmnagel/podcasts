import Foundation

struct FeedChapterExtractor: Sendable {
    func rssChapters(from data: Data, relativeTo feedURL: String) -> [String: FeedChapterSet] {
        let parser = RSSChapterXMLParser(feedURL: feedURL)
        return parser.parse(data: data)
    }

    func podcastChapters(from data: Data, relativeTo chapterURL: String) -> [FeedEpisodeChapter] {
        if let envelope = try? JSONDecoder().decode(PodcastChaptersEnvelope.self, from: data) {
            return envelope.chapters.normalized(relativeTo: chapterURL)
        }
        if let chapters = try? JSONDecoder().decode([PodcastJSONChapter].self, from: data) {
            return chapters.normalized(relativeTo: chapterURL)
        }
        return []
    }
}

struct FeedChapterSet: Sendable {
    var source: String
    var chapters: [FeedEpisodeChapter]
    var remoteURL: String?
}

struct FeedEpisodeChapter: Codable, Sendable {
    let start: TimeInterval
    let end: TimeInterval?
    let title: String
    let imageURL: String?
    let artworkURL: String?
    let url: String?
}

private final class RSSChapterXMLParser: NSObject, XMLParserDelegate {
    private let feedURL: String
    private var path: [String] = []
    private var currentItem = RSSChapterItem()
    private var results: [String: FeedChapterSet] = [:]

    init(feedURL: String) {
        self.feedURL = feedURL
    }

    func parse(data: Data) -> [String: FeedChapterSet] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        _ = parser.parse()
        return results
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = localName(qName ?? elementName).lowercased()
        path.append(name)

        if name == "item" {
            currentItem = RSSChapterItem()
        } else if isInsideItem {
            switch name {
            case "guid":
                currentItem.captureTextFor = "guid"
            case "enclosure":
                currentItem.enclosureURL = attributeDict.caseInsensitiveValue("url")
            case "chapters":
                if let url = attributeDict.caseInsensitiveValue("url") {
                    currentItem.remoteChaptersURL = absoluteURLString(url, relativeTo: feedURL)
                    currentItem.remoteChaptersType = attributeDict.caseInsensitiveValue("type")
                }
            case "chapter":
                if isInsideChapters, let chapter = chapter(from: attributeDict) {
                    currentItem.inlineChapters.append(chapter)
                }
            default:
                break
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInsideItem, currentItem.captureTextFor != nil else { return }
        currentItem.capturedText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(qName ?? elementName).lowercased()
        if name == "guid", currentItem.captureTextFor == "guid" {
            currentItem.guid = currentItem.capturedText.trimmingCharacters(in: .whitespacesAndNewlines)
            currentItem.captureTextFor = nil
            currentItem.capturedText = ""
        }

        if name == "item", let key = currentItem.key {
            if currentItem.inlineChapters.count > 1 {
                results[key] = FeedChapterSet(source: "feed-psc", chapters: currentItem.inlineChapters.normalizedByStart(), remoteURL: nil)
            } else if let remoteURL = currentItem.remoteChaptersURL {
                results[key] = FeedChapterSet(source: "feed-podcast-json", chapters: [], remoteURL: remoteURL)
            }
        }
        _ = path.popLast()
    }

    private var isInsideItem: Bool {
        path.contains("item")
    }

    private var isInsideChapters: Bool {
        path.contains("chapters")
    }

    private func chapter(from attributes: [String: String]) -> FeedEpisodeChapter? {
        guard let rawStart = attributes.caseInsensitiveValue("start") ?? attributes.caseInsensitiveValue("startTime"),
              let start = TimeInterval.chapterTime(rawStart),
              let title = attributes.caseInsensitiveValue("title")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        return FeedEpisodeChapter(
            start: start,
            end: attributes.caseInsensitiveValue("end").flatMap(TimeInterval.chapterTime),
            title: title,
            imageURL: attributes.caseInsensitiveValue("image").flatMap { absoluteURLString($0, relativeTo: feedURL) },
            artworkURL: attributes.caseInsensitiveValue("img").flatMap { absoluteURLString($0, relativeTo: feedURL) },
            url: attributes.caseInsensitiveValue("href").flatMap { absoluteURLString($0, relativeTo: feedURL) }
        )
    }

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

private struct RSSChapterItem {
    var guid: String?
    var enclosureURL: String?
    var remoteChaptersURL: String?
    var remoteChaptersType: String?
    var inlineChapters: [FeedEpisodeChapter] = []
    var captureTextFor: String?
    var capturedText = ""

    var key: String? {
        let guid = guid?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let guid, !guid.isEmpty { return "guid:\(guid)" }
        let enclosureURL = enclosureURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let enclosureURL, !enclosureURL.isEmpty { return "audio:\(enclosureURL)" }
        return nil
    }
}

private struct PodcastChaptersEnvelope: Decodable {
    let chapters: [PodcastJSONChapter]
}

private struct PodcastJSONChapter: Decodable {
    let startTime: ChapterStartValue?
    let start: ChapterStartValue?
    let title: String
    let img: String?
    let image: String?
    let imageURL: String?
    let artworkURL: String?
    let url: String?
}

private enum ChapterStartValue: Decodable {
    case seconds(TimeInterval)
    case string(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .seconds(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case let .seconds(value): value
        case let .string(value): TimeInterval.chapterTime(value)
        }
    }
}

private extension Array where Element == PodcastJSONChapter {
    func normalized(relativeTo baseURL: String) -> [FeedEpisodeChapter] {
        compactMap { chapter in
            guard let start = (chapter.startTime ?? chapter.start)?.seconds,
                  !chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return FeedEpisodeChapter(
                start: start,
                end: nil,
                title: chapter.title.trimmingCharacters(in: .whitespacesAndNewlines),
                imageURL: firstAbsoluteURL(chapter.imageURL, chapter.image, relativeTo: baseURL),
                artworkURL: firstAbsoluteURL(chapter.artworkURL, chapter.img, relativeTo: baseURL),
                url: chapter.url.flatMap { absoluteURLString($0, relativeTo: baseURL) }
            )
        }
        .normalizedByStart()
    }
}

private extension Array where Element == FeedEpisodeChapter {
    func normalizedByStart() -> [FeedEpisodeChapter] {
        var starts: Set<Int> = []
        return sorted { $0.start < $1.start }
            .filter { starts.insert(Int($0.start.rounded())).inserted }
    }
}

private extension Dictionary where Key == String, Value == String {
    func caseInsensitiveValue(_ key: String) -> String? {
        first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

private extension TimeInterval {
    static func chapterTime(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed), seconds.isFinite, seconds >= 0 { return seconds }
        let parts = trimmed.split(separator: ":").map(String.init)
        guard parts.count >= 2, parts.count <= 3 else { return nil }
        let seconds = TimeInterval(parts.last ?? "")
        let minutes = TimeInterval(parts.dropLast().last ?? "")
        let hours = parts.count == 3 ? TimeInterval(parts.first ?? "") : 0
        guard let seconds, let minutes, let hours else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}

private func firstAbsoluteURL(_ values: String?..., relativeTo baseURL: String) -> String? {
    values.lazy.compactMap { $0 }.first.flatMap { absoluteURLString($0, relativeTo: baseURL) }
}

private func absoluteURLString(_ value: String, relativeTo baseURL: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let base = URL(string: baseURL) else { return trimmed }
    return URL(string: trimmed, relativeTo: base)?.absoluteURL.absoluteString ?? trimmed
}
