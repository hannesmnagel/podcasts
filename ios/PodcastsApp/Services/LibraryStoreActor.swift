import Foundation
import SwiftData

/// Background `@ModelActor` that handles the DB-heavy operations which previously
/// ran on the main actor and caused UIKit-runloop hangs (>500 ms in Low Power Mode).
///
/// - `cacheEpisodes`: replaces the `@MainActor LibraryStore.cacheEpisodes` hot path.
///   Writes + saves on a background context, so SwiftData's autosave timer never
///   accumulates a large pending batch on the main context.
/// - `fetchLocalEpisodes` / `fetchDisplayData`: replace the synchronous
///   `allEpisodeStates(in:)` calls that ran on the main thread during every load.
@ModelActor
actor LibraryStoreActor {

    // MARK: - Write

    func cacheEpisodes(_ episodes: [EpisodeDTO]) async {
        let prepared = await EpisodeDataProcessor.prepare(episodes)
        let wantedIDs = Set(prepared.map(\.episode.stableID))
        guard !wantedIDs.isEmpty else { return }

        let allStates = (try? modelContext.fetch(FetchDescriptor<LocalEpisodeState>())) ?? []
        var statesByID: [String: LocalEpisodeState] = [:]
        for state in allStates where wantedIDs.contains(state.episodeStableID) {
            statesByID[state.episodeStableID] = state
        }

        for preparedEpisode in prepared {
            let episode = preparedEpisode.episode
            let state: LocalEpisodeState
            if let existing = statesByID[episode.stableID] {
                state = existing
            } else {
                let s = LocalEpisodeState(
                    episodeStableID: episode.stableID,
                    podcastStableID: episode.podcastStableID ?? "",
                    title: episode.title,
                    audioURL: URL(string: episode.audioURL) ?? URL(fileURLWithPath: "/")
                )
                s.duration = episode.duration
                s.summary = episode.summary
                s.strippedSummary = nil
                s.imageURL = episode.imageURL.flatMap(URL.init(string:))
                s.publishedAt = episode.publishedAt
                s.cachedAt = .now
                modelContext.insert(s)
                state = s
            }
            state.podcastStableID = episode.podcastStableID ?? state.podcastStableID
            state.title = episode.title
            state.summary = episode.summary
            state.strippedSummary = preparedEpisode.strippedSummary
            state.audioURL = preparedEpisode.audioURL ?? state.audioURL
            state.imageURL = preparedEpisode.imageURL
            state.publishedAt = episode.publishedAt
            state.duration = episode.duration ?? state.duration
            state.cachedAt = .now
        }
        try? modelContext.save()
    }

    // MARK: - Read

    func fetchLocalEpisodes(forPodcastIDs podcastIDs: [String]) -> [EpisodeDTO] {
        guard !podcastIDs.isEmpty else { return [] }
        let states = (try? modelContext.fetch(FetchDescriptor<LocalEpisodeState>())) ?? []
        return states
            .filter { !$0.isDeleted && podcastIDs.contains($0.podcastStableID) && $0.cachedAt != nil }
            .map { $0.episodeDTO(preferDownloadedFile: true) }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    func fetchLocalEpisodes(matching query: String) -> [EpisodeDTO] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let states = (try? modelContext.fetch(FetchDescriptor<LocalEpisodeState>())) ?? []
        return states
            .filter {
                !$0.isDeleted && $0.cachedAt != nil
                    && ($0.title.lowercased().contains(trimmed)
                        || ($0.summary?.lowercased().contains(trimmed) ?? false))
            }
            .map { $0.episodeDTO(preferDownloadedFile: true) }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    func fetchDisplayData(for episodes: [EpisodeDTO]) -> LibraryStore.EpisodeDisplayData {
        guard !episodes.isEmpty else {
            return LibraryStore.EpisodeDisplayData(
                playedIDs: [], deletedIDs: [], downloadedIDs: [],
                summarySnippets: [:], artworkURLs: [:]
            )
        }
        let episodeIDSet = Set(episodes.map(\.stableID))
        let podcastIDs = Array(Set(episodes.compactMap(\.podcastStableID)))

        let allStates = (try? modelContext.fetch(FetchDescriptor<LocalEpisodeState>())) ?? []
        let states = allStates.filter { episodeIDSet.contains($0.episodeStableID) }

        var played: Set<String> = []
        var deleted: Set<String> = []
        var downloaded: Set<String> = []
        var snippets: [String: String] = [:]
        var cachedImageURLs: [String: URL] = [:]

        for state in states {
            let id = state.episodeStableID
            if state.isDeleted { deleted.insert(id) }
            if state.isDownloaded { downloaded.insert(id) }
            if let duration = state.duration, duration > 0 {
                if state.playbackPosition >= max(0, duration - 30) { played.insert(id) }
            } else if state.lastListenedAt != nil {
                played.insert(id)
            }
            if let snippet = state.strippedSummary, !snippet.isEmpty { snippets[id] = snippet }
            if let url = state.cachedImageFileURL { cachedImageURLs[id] = url }
        }

        var podcastArtwork: [String: URL] = [:]
        if !podcastIDs.isEmpty {
            let pidSet = Set(podcastIDs)
            let allSubs = (try? modelContext.fetch(FetchDescriptor<PodcastSubscription>())) ?? []
            for sub in allSubs where pidSet.contains(sub.stableID) {
                guard let url = sub.artworkURL else { continue }
                let cached = LocalMediaCache.cachedFileURL(for: url)
                podcastArtwork[sub.stableID] = FileManager.default.fileExists(atPath: cached.path) ? cached : url
            }
        }

        var artworkURLs: [String: URL] = [:]
        artworkURLs.reserveCapacity(episodes.count)
        for ep in episodes {
            if let url = cachedImageURLs[ep.stableID] {
                artworkURLs[ep.stableID] = url
            } else if let url = ep.imageURL.flatMap(URL.init) {
                artworkURLs[ep.stableID] = url
            } else if let pid = ep.podcastStableID, let fallback = podcastArtwork[pid] {
                artworkURLs[ep.stableID] = fallback
            }
        }

        return LibraryStore.EpisodeDisplayData(
            playedIDs: played, deletedIDs: deleted, downloadedIDs: downloaded,
            summarySnippets: snippets, artworkURLs: artworkURLs
        )
    }
}
