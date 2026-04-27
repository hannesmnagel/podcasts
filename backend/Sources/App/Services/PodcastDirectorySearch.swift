import Foundation
import Vapor

struct PodcastDirectorySearch: Sendable {
    func search(term: String, on app: Application) async throws -> [PodcastDirectoryResult] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "term", value: term)
        ]
        guard let url = components.url else { throw Abort(.badRequest) }
        let response = try await app.client.get(URI(string: url.absoluteString), headers: ["User-Agent": "PrivacySpeedPodcastsBot/0.1 (+https://hannesnagel.com)"])
        guard response.status == .ok else { throw Abort(.badGateway, reason: "Podcast directory search failed") }
        guard let body = response.body else { return [] }
        let output = try JSONDecoder().decode(ITunesSearchResponse.self, from: Data(buffer: body))
        return output.results.compactMap { result in
            guard let feedURL = result.feedUrl, !feedURL.isEmpty else { return nil }
            return PodcastDirectoryResult(
                title: result.collectionName ?? result.trackName ?? feedURL,
                feedURL: feedURL,
                artistName: result.artistName,
                artworkURL: result.artworkUrl600 ?? result.artworkUrl100,
                directoryURL: result.collectionViewUrl ?? result.trackViewUrl
            )
        }
    }
}

struct PodcastDirectoryResult: Content {
    let title: String
    let feedURL: String
    let artistName: String?
    let artworkURL: String?
    let directoryURL: String?
}

private struct ITunesSearchResponse: Decodable {
    let results: [ITunesPodcastResult]
}

private struct ITunesPodcastResult: Decodable {
    let collectionName: String?
    let trackName: String?
    let artistName: String?
    let feedUrl: String?
    let artworkUrl100: String?
    let artworkUrl600: String?
    let collectionViewUrl: String?
    let trackViewUrl: String?
}
