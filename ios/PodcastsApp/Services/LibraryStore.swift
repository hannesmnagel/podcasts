import Foundation
import SwiftData

@MainActor
enum LibraryStore {
    static func subscribe(to podcast: PodcastDTO, in context: ModelContext) {
        let stableID = podcast.stableID
        let descriptor = FetchDescriptor<PodcastSubscription>(predicate: #Predicate { $0.stableID == stableID })
        if let existing = try? context.fetch(descriptor).first {
            existing.title = podcast.title.isEmpty ? existing.title : podcast.title
            existing.artworkURL = podcast.imageURL.flatMap(URL.init(string:)) ?? existing.artworkURL
            existing.feedURL = URL(string: podcast.feedURL) ?? existing.feedURL
            return
        }
        guard let feedURL = URL(string: podcast.feedURL) else { return }
        let subscription = PodcastSubscription(
            stableID: stableID,
            feedURL: feedURL,
            title: podcast.title.isEmpty ? podcast.feedURL : podcast.title,
            artworkURL: podcast.imageURL.flatMap(URL.init(string:))
        )
        context.insert(subscription)
    }

    static func episodeState(for episode: EpisodeDTO, in context: ModelContext) -> LocalEpisodeState? {
        let stableID = episode.stableID
        let descriptor = FetchDescriptor<LocalEpisodeState>(predicate: #Predicate { $0.episodeStableID == stableID })
        return try? context.fetch(descriptor).first
    }

    static func markPlayed(_ episode: EpisodeDTO, in context: ModelContext) {
        let state = episodeState(for: episode, in: context) ?? makeEpisodeState(for: episode, in: context)
        state.playbackPosition = episode.duration ?? state.duration ?? 0
        state.duration = episode.duration ?? state.duration
        state.lastListenedAt = .now
    }

    static func markUnplayed(_ episode: EpisodeDTO, in context: ModelContext) {
        let state = episodeState(for: episode, in: context) ?? makeEpisodeState(for: episode, in: context)
        state.playbackPosition = 0
        state.duration = episode.duration ?? state.duration
        state.lastListenedAt = nil
    }

    static func isPlayed(_ episode: EpisodeDTO, in context: ModelContext) -> Bool {
        guard let state = episodeState(for: episode, in: context) else { return false }
        if let duration = state.duration, duration > 0 {
            return state.playbackPosition >= max(0, duration - 30)
        }
        return state.lastListenedAt != nil
    }

    private static func makeEpisodeState(for episode: EpisodeDTO, in context: ModelContext) -> LocalEpisodeState {
        let state = LocalEpisodeState(
            episodeStableID: episode.stableID,
            podcastStableID: episode.podcastStableID ?? "",
            title: episode.title,
            audioURL: URL(string: episode.audioURL) ?? URL(fileURLWithPath: "/")
        )
        state.duration = episode.duration
        context.insert(state)
        return state
    }
}
