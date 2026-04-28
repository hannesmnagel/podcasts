import Foundation

struct PreparedEpisode: Sendable {
    let episode: EpisodeDTO
    let strippedSummary: String?
    let audioURL: URL?
    let imageURL: URL?
}

enum EpisodeDataProcessor {
    @concurrent
    static func prepare(_ episodes: [EpisodeDTO]) async -> [PreparedEpisode] {
        episodes.map { episode in
            PreparedEpisode(
                episode: episode,
                strippedSummary: episode.summary.map(ShowNotesProcessor.plainText),
                audioURL: URL(string: episode.audioURL),
                imageURL: episode.imageURL.flatMap(URL.init(string:))
            )
        }
    }

    @concurrent
    static func decodeChapterImageFiles(_ data: Data?) async -> [String: String] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    @concurrent
    static func encodeChapterImageFiles(_ mapping: [String: String]) async -> Data? {
        try? JSONEncoder().encode(mapping)
    }
}
