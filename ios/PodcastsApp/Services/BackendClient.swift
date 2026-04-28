import Foundation

struct BackendClient: Sendable {
    var baseURL: URL = AppConfiguration.backendBaseURL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init() {
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    func podcasts() async throws -> [PodcastDTO] { try await get("podcasts") }

    func addPodcast(feedURL: URL) async throws -> PodcastDTO {
        try await post("podcasts", body: CreatePodcastDTO(feedURL: feedURL.absoluteString, title: nil, crawlImmediately: true))
    }

    func allEpisodes(limit: Int = 100) async throws -> [EpisodeDTO] {
        try await get("episodes?limit=\(limit)")
    }

    func episodes(for podcastID: String) async throws -> [EpisodeDTO] {
        try await get("podcasts/\(podcastID)/episodes")
    }

    func search(_ query: String) async throws -> EpisodeSearchDTO {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return try await get("episodes/search?q=\(encoded)")
    }

    @discardableResult
    func requestArtifacts(for episodeID: String) async throws -> ArtifactRequestDTO {
        try await post("episodes/\(episodeID)/artifact-requests", body: ArtifactDemandDTO(transcript: true, chapters: true, fingerprint: false))
    }

    func transcript(for episodeID: String) async throws -> TranscriptArtifactDTO {
        try await get("episodes/\(episodeID)/transcript")
    }

    func chapters(for episodeID: String) async throws -> ChapterArtifactDTO {
        try await get("episodes/\(episodeID)/chapters")
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url(for: path))
        try validate(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(T.self, from: data)
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
    case server(status: Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .notFound: "Not found"
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
    let textHash: String
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
