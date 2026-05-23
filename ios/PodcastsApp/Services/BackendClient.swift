import CryptoKit
import Foundation

struct BackendClient: Sendable {
    var baseURL: URL = AppConfiguration.backendBaseURL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init() {
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    private func checkNetwork() throws {
        if NetworkMonitor.shared.isOffline {
            throw BackendError.offline
        }
    }

    func podcasts(limit: Int = 500) async throws -> [PodcastDTO] {
        let clamped = min(max(limit, 1), 500)
        return try await get("podcasts?limit=\(clamped)")
    }

    func optimisticPodcast(feedURL: URL, title: String? = nil, imageURL: String? = nil) -> PodcastDTO {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedImageURL = imageURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PodcastDTO(
            id: nil,
            stableID: StableID.podcastID(feedURL: feedURL),
            feedURL: feedURL.absoluteString,
            title: trimmedTitle?.isEmpty == false ? trimmedTitle! : feedURL.absoluteString,
            description: nil,
            imageURL: trimmedImageURL?.isEmpty == false ? trimmedImageURL : nil
        )
    }

    func addPodcast(feedURL: URL) async throws -> PodcastDTO {
        try await post("podcasts", body: CreatePodcastDTO(feedURL: feedURL.absoluteString, title: nil, crawlImmediately: false))
    }

    func crawlPodcast(_ podcastID: String) async throws -> PodcastDTO {
        try await post("podcasts/\(podcastID)/crawl")
    }

    @discardableResult
    func requestPodcastCrawl(_ podcastID: String) async -> Bool {
        (try? await postEmpty("podcasts/\(podcastID)/crawl-request")) != nil
    }

    func hydratedPodcast(afterAdding podcast: PodcastDTO) async -> PodcastDTO {
        if podcast.hasDisplayMetadata { return podcast }

        // Do not call the synchronous crawl endpoint from the add flow: first-time
        // crawls can take long enough to hit the reverse-proxy timeout and surface
        // as a 502 even though the podcast was created. Ask the backend to crawl
        // asynchronously, poll briefly for metadata, and otherwise subscribe to
        // the placeholder immediately.
        await requestPodcastCrawl(podcast.stableID)
        for delay in [250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000] {
            try? await Task.sleep(nanoseconds: UInt64(delay))
            guard let refreshed = try? await podcasts().first(where: { $0.stableID == podcast.stableID }) else {
                continue
            }
            if refreshed.hasDisplayMetadata {
                return refreshed
            }
        }

        return (try? await podcasts().first(where: { $0.stableID == podcast.stableID })) ?? podcast
    }

    func allEpisodes(limit: Int = 100) async throws -> [EpisodeDTO] {
        try await get("episodes?limit=\(limit)")
    }

    func episodes(for podcastID: String, limit: Int = 1000) async throws -> [EpisodeDTO] {
        let clamped = min(max(limit, 1), 1000)
        return try await get("podcasts/\(podcastID)/episodes?limit=\(clamped)")
    }

    func search(_ query: String) async throws -> EpisodeSearchDTO {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return try await get("episodes/search?q=\(encoded)")
    }

    @discardableResult
    func requestArtifacts(for episodeID: String) async throws -> ArtifactRequestDTO {
        try await post("episodes/\(episodeID)/artifact-requests", body: ArtifactDemandDTO(transcript: true, chapters: true, fingerprint: true))
    }

    func transcript(for episodeID: String) async throws -> TranscriptArtifactDTO {
        try await get("episodes/\(episodeID)/transcript")
    }

    func transcriptVersion(for episodeID: String) async throws -> TranscriptVersionDTO {
        try await get("episodes/\(episodeID)/transcript-version")
    }

    func fingerprint(for episodeID: String) async throws -> AudioFingerprintDTO {
        try await get("episodes/\(episodeID)/fingerprint")
    }

    func chapters(for episodeID: String) async throws -> ChapterArtifactDTO {
        try await get("episodes/\(episodeID)/chapters")
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try checkNetwork()
        let (data, response) = try await URLSession.shared.data(from: url(for: path))
        try validate(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        try checkNetwork()
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String) async throws -> T {
        try checkNetwork()
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func postEmpty(_ path: String) async throws {
        try checkNetwork()
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
    }

    private func url(for path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 404 { throw BackendError.notFound }
            throw BackendError.server(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
    }
}

enum BackendError: LocalizedError {
    case notFound
    case offline
    case server(status: Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .notFound: "Not found"
        case .offline: "No internet connection"
        case let .server(status, body): "Server error \(status): \(body ?? "")"
        }
    }
}

enum AppConfiguration {
    static var backendBaseURL: URL {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String,
           let url = URL(string: raw), !raw.isEmpty {
            return url
        }
        return URL(string: "http://localhost:8080")!
    }
}

struct PodcastDTO: Codable, Identifiable, Hashable, Sendable {
    let id: UUID?
    let stableID: String
    let feedURL: String
    let title: String
    let description: String?
    let imageURL: String?

    var hasDisplayMetadata: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && imageURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func fillingMissingImageURL(_ fallback: String?) -> PodcastDTO {
        let trimmedFallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard imageURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              trimmedFallback?.isEmpty == false else {
            return self
        }
        return PodcastDTO(
            id: id,
            stableID: stableID,
            feedURL: feedURL,
            title: title,
            description: description,
            imageURL: trimmedFallback
        )
    }
}

struct EpisodeDTO: Codable, Identifiable, Hashable, Sendable {
    let id: UUID?
    let podcastStableID: String?
    let stableID: String
    let title: String
    let summary: String?
    let audioURL: String
    let imageURL: String?
    let publishedAt: Date?
    let duration: TimeInterval?
}

struct EpisodeSearchDTO: Codable, Hashable, Sendable {
    let podcasts: [PodcastDTO]
    let episodes: [EpisodeDTO]
    let directory: [PodcastDirectoryDTO]

    init(podcasts: [PodcastDTO] = [], episodes: [EpisodeDTO] = [], directory: [PodcastDirectoryDTO] = []) {
        self.podcasts = podcasts
        self.episodes = episodes
        self.directory = directory
    }
}

struct PodcastDirectoryDTO: Codable, Identifiable, Hashable, Sendable {
    let title: String
    let feedURL: String
    let artistName: String?
    let artworkURL: String?
    let directoryURL: String?

    var id: String { feedURL }
}

struct CreatePodcastDTO: Codable, Sendable {
    let feedURL: String
    let title: String?
    let crawlImmediately: Bool?
}

struct ArtifactDemandDTO: Codable, Sendable {
    let transcript: Bool
    let chapters: Bool
    let fingerprint: Bool
}

struct ArtifactRequestDTO: Codable, Sendable {
    let episodeID: String
    let transcriptCount: Int
    let chapterCount: Int
    let fingerprintCount: Int
}

struct TranscriptArtifactDTO: Codable, Hashable, Sendable {
    let id: UUID?
    let locale: String
    let model: String
    let segmentsJSON: String
    let segmentFingerprintsJSON: String?
    let textHash: String
    let renditionID: String?
}

struct TranscriptVersionDTO: Codable, Hashable, Sendable {
    let id: UUID?
    let textHash: String
    let renditionID: String?
    let model: String
    let hasSegmentFingerprints: Bool
    let createdAt: Date?
}

struct ChapterArtifactDTO: Codable, Hashable, Sendable {
    let id: UUID?
    let source: String
    let chaptersJSON: String
}

struct EpisodeChapterDTO: Codable, Identifiable, Hashable, Sendable {
    let start: TimeInterval
    let end: TimeInterval?
    let title: String
    let imageURL: String?
    let artworkURL: String?

    var id: String { "\(start)-\(title)" }

    var displayImageURL: URL? {
        (imageURL ?? artworkURL).flatMap(URL.init(string:))
    }
}

enum StableID {
    static func podcastID(feedURL: URL) -> String {
        sha256(normalizeURL(feedURL.absoluteString))
    }

    static func episodeID(podcastID: String, guid: String?, audioURL: String, title: String, publishedAt: Date?) -> String {
        let formatter = ISO8601DateFormatter()
        let published = publishedAt.map { formatter.string(from: $0) } ?? ""
        let source = [podcastID, guid ?? "", normalizeURL(audioURL), title.trimmingCharacters(in: .whitespacesAndNewlines), published]
            .joined(separator: "|")
        return sha256(source)
    }

    private static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed.lowercased() }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        return components.string ?? trimmed.lowercased()
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
