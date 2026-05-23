import Foundation
import SwiftData

@ModelActor
actor BackgroundRefreshStore {
    private struct SubscriptionSnapshot: Sendable {
        let stableID: String
        let policy: EpisodeDownloadPolicy
    }

    func refreshAndApplyDownloadPolicies() async -> Bool {
        guard !NetworkMonitor.shared.isOffline else { return false }
        let client = BackendClient()
        let subscriptions = loadSubscriptionSnapshots()
        guard !subscriptions.isEmpty else { return false }

        var changed = false
        for subscription in subscriptions {
            guard !Task.isCancelled else { return changed }
            let stableID = subscription.stableID
            let policy = subscription.policy

            await client.requestPodcastCrawl(stableID)
            guard let fetched = try? await client.fetchAllEpisodes(for: stableID) else {
                await Task.yield()
                continue
            }

            await cacheEpisodes(fetched)
            let localEpisodes = localEpisodes(forPodcastID: stableID)
            let downloaded = await applyDownloadPolicy(to: localEpisodes, policy: policy)
            changed = changed || downloaded > 0 || !fetched.isEmpty
            await Task.yield()
        }

        return changed
    }

    private func cacheEpisodes(_ episodes: [EpisodeDTO]) async {
        let prepared = await EpisodeDataProcessor.prepare(episodes)
        let statesByID = existingEpisodeStates(for: prepared.map(\.episode.stableID))
        for preparedEpisode in prepared {
            let episode = preparedEpisode.episode
            let state = statesByID[episode.stableID] ?? makeEpisodeState(for: episode)
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
    }

    private func localEpisodes(forPodcastID podcastID: String) -> [EpisodeDTO] {
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? modelContext.fetch(descriptor)) ?? []
        return states
            .filter { !$0.isDeleted && $0.podcastStableID == podcastID && $0.cachedAt != nil }
            .map { $0.episodeDTO(preferDownloadedFile: true) }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    private func applyDownloadPolicy(to episodes: [EpisodeDTO], policy: EpisodeDownloadPolicy) async -> Int {
        let targets: [EpisodeDTO]
        switch policy {
        case .manual:
            targets = []
        case .latest:
            targets = Array(episodes.prefix(1))
        case .unplayed:
            let playedIDs = playedEpisodeIDs(for: episodes)
            targets = episodes.filter { !playedIDs.contains($0.stableID) }
        case .all:
            targets = episodes
        }

        let downloadedIDs = downloadedEpisodeIDs(for: targets)
        var completed = 0
        for episode in targets where !downloadedIDs.contains(episode.stableID) {
            if await downloadAudio(for: episode) {
                completed += 1
            }
            await Task.yield()
        }
        return completed
    }

    private func downloadAudio(for episode: EpisodeDTO) async -> Bool {
        guard let remoteURL = URL(string: episode.audioURL) else { return false }
        let state = episodeState(for: episode) ?? makeEpisodeState(for: episode)

        if remoteURL.isFileURL, FileManager.default.fileExists(atPath: remoteURL.path) {
            state.downloadedFileURL = remoteURL
            state.isDownloaded = true
            try? modelContext.save()
            return true
        }

        if let cachedURL = await LocalMediaCache.existingCachedFileURL(for: remoteURL) {
            state.downloadedFileURL = cachedURL
            state.isDownloaded = true
            try? modelContext.save()
            return true
        }

        do {
            let localURL = try await LocalMediaCache.cachedOrDownload(remoteURL, progressID: nil)
            state.downloadedFileURL = localURL
            state.isDownloaded = true
            try? modelContext.save()
            return true
        } catch {
            return false
        }
    }

    private func loadSubscriptionSnapshots() -> [SubscriptionSnapshot] {
        var descriptor = FetchDescriptor<PodcastSubscription>(sortBy: [SortDescriptor(\.sortIndex)])
        descriptor.includePendingChanges = true
        let subscriptions = (try? modelContext.fetch(descriptor)) ?? []
        return subscriptions.map { subscription in
            SubscriptionSnapshot(
                stableID: subscription.stableID,
                policy: DownloadSettings.policy(for: subscription)
            )
        }
    }

    private func episodeState(for episode: EpisodeDTO) -> LocalEpisodeState? {
        let stableID = episode.stableID
        let descriptor = FetchDescriptor<LocalEpisodeState>(predicate: #Predicate { $0.episodeStableID == stableID })
        return try? modelContext.fetch(descriptor).first
    }

    private func makeEpisodeState(for episode: EpisodeDTO) -> LocalEpisodeState {
        let state = LocalEpisodeState(
            episodeStableID: episode.stableID,
            podcastStableID: episode.podcastStableID ?? "",
            title: episode.title,
            audioURL: URL(string: episode.audioURL) ?? URL(fileURLWithPath: "/")
        )
        state.duration = episode.duration
        state.summary = episode.summary
        state.strippedSummary = nil
        state.imageURL = episode.imageURL.flatMap(URL.init(string:))
        state.publishedAt = episode.publishedAt
        state.cachedAt = .now
        modelContext.insert(state)
        return state
    }

    private func existingEpisodeStates(for episodeIDs: [String]) -> [String: LocalEpisodeState] {
        let wanted = Set(episodeIDs)
        guard !wanted.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? modelContext.fetch(descriptor)) ?? []
        return Dictionary(uniqueKeysWithValues: states.compactMap { state in
            wanted.contains(state.episodeStableID) ? (state.episodeStableID, state) : nil
        })
    }

    private func downloadedEpisodeIDs(for episodes: [EpisodeDTO]) -> Set<String> {
        let ids = Set(episodes.map(\.stableID))
        guard !ids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? modelContext.fetch(descriptor)) ?? []
        return Set(states.compactMap { state in
            ids.contains(state.episodeStableID) && state.isDownloaded ? state.episodeStableID : nil
        })
    }

    private func playedEpisodeIDs(for episodes: [EpisodeDTO]) -> Set<String> {
        let ids = Set(episodes.map(\.stableID))
        guard !ids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? modelContext.fetch(descriptor)) ?? []
        var played: Set<String> = []
        for state in states where ids.contains(state.episodeStableID) {
            if let duration = state.duration, duration > 0 {
                if state.playbackPosition >= max(0, duration - 30) {
                    played.insert(state.episodeStableID)
                }
            } else if state.lastListenedAt != nil {
                played.insert(state.episodeStableID)
            }
        }
        return played
    }
}
