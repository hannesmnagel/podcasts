import Foundation
import SwiftData

@MainActor
enum LibraryStore {
    private static let lastPlaybackEpisodeIDKey = "playbackState.lastEpisodeStableID"
    private static let embeddedChapterSource = "id3 embedded v2"

    static func subscribe(to podcast: PodcastDTO, in context: ModelContext) {
        let stableID = podcast.stableID
        let descriptor = FetchDescriptor<PodcastSubscription>(predicate: #Predicate { $0.stableID == stableID })
        if let existing = try? context.fetch(descriptor).first {
            existing.title = nonEmpty(podcast.title) ?? existing.title
            existing.podcastDescription = nonEmpty(podcast.description) ?? existing.podcastDescription
            existing.artworkURL = nonEmpty(podcast.imageURL).flatMap(URL.init(string:)) ?? existing.artworkURL
            existing.feedURL = URL(string: podcast.feedURL) ?? existing.feedURL
            prefetchArtwork(for: existing.artworkURL)
            try? context.save()
            return
        }
        guard let feedURL = URL(string: podcast.feedURL) else { return }
        let subscription = PodcastSubscription(
            stableID: stableID,
            feedURL: feedURL,
            title: nonEmpty(podcast.title) ?? podcast.feedURL,
            artworkURL: nonEmpty(podcast.imageURL).flatMap(URL.init(string:)),
            sortIndex: 0
        )
        subscription.podcastDescription = nonEmpty(podcast.description)
        context.insert(subscription)
        prefetchArtwork(for: subscription.artworkURL)
        try? context.save()
    }

    static func subscribe(to podcasts: [PodcastDTO], in context: ModelContext) {
        podcasts.forEach { subscribe(to: $0, in: context) }
    }

    static func updateExistingSubscriptions(with podcasts: [PodcastDTO], in context: ModelContext) {
        let descriptor = FetchDescriptor<PodcastSubscription>()
        let existing = (try? context.fetch(descriptor)) ?? []
        let existingIDs = Set(existing.map(\.stableID))
        podcasts
            .filter { existingIDs.contains($0.stableID) }
            .forEach { subscribe(to: $0, in: context) }
    }

    static func unsubscribe(_ subscription: PodcastSubscription, in context: ModelContext) {
        let podcastID = subscription.stableID
        let stateDescriptor = FetchDescriptor<LocalEpisodeState>()
        let states = ((try? context.fetch(stateDescriptor)) ?? []).filter { $0.podcastStableID == podcastID }
        let episodeIDs = Set(states.map(\.episodeStableID))
        let progressIDsToCancel = Set(episodeIDs.flatMap { [$0, "policy-\($0)"] })
        Task { await LocalMediaCache.cancelDownloads(progressIDs: progressIDsToCancel) }
        states.forEach { state in
            if let downloadedFileURL = state.downloadedFileURL {
                Task { await LocalMediaCache.removeFileIfPresent(at: downloadedFileURL) }
            }
            context.delete(state)
        }

        let artifactDescriptor = FetchDescriptor<LocalEpisodeArtifact>()
        let artifacts = (try? context.fetch(artifactDescriptor)) ?? []
        artifacts.filter { episodeIDs.contains($0.episodeStableID) }.forEach {
            context.delete($0)
        }
        context.delete(subscription)
        try? context.save()
    }

    /// Adds a single episode to the library without subscribing to its podcast.
    /// The episode is cached and flagged so it surfaces in the Episodes tab.
    static func saveSingleEpisode(_ episode: EpisodeDTO, in context: ModelContext) async {
        await cacheEpisode(episode, in: context)
        let state = episodeState(for: episode, in: context) ?? makeEpisodeState(for: episode, in: context)
        state.isSaved = true
        state.isDeleted = false
        state.deletedAt = nil
        if state.cachedAt == nil { state.cachedAt = .now }
        try? context.save()
    }

    static func unsaveSingleEpisode(_ episode: EpisodeDTO, in context: ModelContext) {
        guard let state = episodeState(for: episode, in: context) else { return }
        state.isSaved = false
        try? context.save()
    }

    static func isEpisodeSaved(_ episode: EpisodeDTO, in context: ModelContext) -> Bool {
        episodeState(for: episode, in: context)?.isSaved ?? false
    }

    /// Standalone saved episodes whose podcast is not in `subscriptionIDs`.
    static func savedStandaloneEpisodes(excludingPodcastIDs subscriptionIDs: [String], in context: ModelContext) -> [EpisodeDTO] {
        let excluded = Set(subscriptionIDs)
        let states = (try? context.fetch(FetchDescriptor<LocalEpisodeState>())) ?? []
        return states
            .filter { $0.isSaved && !$0.isDeleted && !excluded.contains($0.podcastStableID) }
            .map { $0.episodeDTO(preferDownloadedFile: true) }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    static func episodeState(for episode: EpisodeDTO, in context: ModelContext) -> LocalEpisodeState? {
        let stableID = episode.stableID
        let descriptor = FetchDescriptor<LocalEpisodeState>(predicate: #Predicate { $0.episodeStableID == stableID })
        return try? context.fetch(descriptor).first
    }

    static func playbackPosition(for episode: EpisodeDTO, in context: ModelContext) -> TimeInterval {
        let state = episodeState(for: episode, in: context)
        guard let position = state?.playbackPosition, position.isFinite, position > 0 else { return 0 }
        if let duration = state?.duration ?? episode.duration, duration > 0, position >= max(0, duration - 30) {
            return 0
        }
        return position
    }

    static func updatePlaybackState(episode: EpisodeDTO, elapsed: TimeInterval, duration: TimeInterval?, in context: ModelContext) {
        guard elapsed.isFinite, elapsed >= 0 else { return }
        let state = episodeState(for: episode, in: context) ?? makeEpisodeState(for: episode, in: context)
        let knownDuration = duration ?? episode.duration ?? state.duration
        if let knownDuration, knownDuration > 0, elapsed >= max(0, knownDuration - 30) {
            state.playbackPosition = knownDuration
        } else {
            state.playbackPosition = elapsed
        }
        state.duration = knownDuration
        state.lastListenedAt = .now
        UserDefaults.standard.set(episode.stableID, forKey: lastPlaybackEpisodeIDKey)
        // No explicit save — SwiftData autosave flushes this; explicit save only on app background.
    }

    static func lastPlaybackEpisode(in context: ModelContext) -> EpisodeDTO? {
        guard let stableID = UserDefaults.standard.string(forKey: lastPlaybackEpisodeIDKey) else { return nil }
        let descriptor = FetchDescriptor<LocalEpisodeState>(predicate: #Predicate { $0.episodeStableID == stableID })
        return try? context.fetch(descriptor).first?.episodeDTO(preferDownloadedFile: true)
    }

    static func markPlayed(_ episode: EpisodeDTO, in context: ModelContext) {
        let state = episodeState(for: episode, in: context) ?? makeEpisodeState(for: episode, in: context)
        let knownDuration = episode.duration ?? state.duration
        state.playbackPosition = knownDuration ?? 0
        state.duration = knownDuration
        state.lastListenedAt = .now
        try? context.save()
        Task { @MainActor in EventLogger.shared?.log(kind: AppEvent.Kind.markPlayed, episode: episode) }
    }

    static func finishNaturalPlayback(_ episode: EpisodeDTO, in context: ModelContext) {
        markPlayed(episode, in: context)

        if DownloadSettings.completedCleanupPolicy == .afterPlaybackCompletes {
            removeDownload(for: episode, in: context)
            return
        }

        guard let podcastStableID = episode.podcastStableID,
              let subscription = subscription(stableID: podcastStableID, in: context),
              DownloadSettings.policy(for: subscription) == .unplayed else {
            return
        }

        removeDownload(for: episode, in: context)
    }

    static func markUnplayed(_ episode: EpisodeDTO, in context: ModelContext) {
        let state = episodeState(for: episode, in: context) ?? makeEpisodeState(for: episode, in: context)
        state.playbackPosition = 0
        state.duration = episode.duration ?? state.duration
        state.lastListenedAt = nil
        try? context.save()
        Task { @MainActor in EventLogger.shared?.log(kind: AppEvent.Kind.markUnplayed, episode: episode) }
    }

    static func isPlayed(_ episode: EpisodeDTO, in context: ModelContext) -> Bool {
        guard let state = episodeState(for: episode, in: context) else { return false }
        if let duration = state.duration, duration > 0 {
            return state.playbackPosition >= max(0, duration - 30)
        }
        return state.lastListenedAt != nil
    }

    static func markDeleted(_ episode: EpisodeDTO, in context: ModelContext) {
        let state = episodeState(for: episode, in: context) ?? makeEpisodeState(for: episode, in: context)
        state.isDeleted = true
        state.deletedAt = .now
        state.isDownloaded = false
        state.downloadedFileURL = nil
        try? context.save()
        Task { @MainActor in EventLogger.shared?.log(kind: AppEvent.Kind.hide, episode: episode) }
    }

    static func restoreDeleted(_ episode: EpisodeDTO, in context: ModelContext) {
        guard let state = episodeState(for: episode, in: context) else { return }
        state.isDeleted = false
        state.deletedAt = nil
        Task { @MainActor in EventLogger.shared?.log(kind: AppEvent.Kind.restore, episode: episode) }
    }

    static func isDeleted(_ episode: EpisodeDTO, in context: ModelContext) -> Bool {
        episodeState(for: episode, in: context)?.isDeleted ?? false
    }

    @discardableResult
    static func downloadAudio(for episode: EpisodeDTO, in context: ModelContext, progressID: String? = nil) async -> Bool {
        guard let remoteURL = URL(string: episode.audioURL) else { return false }
        let state = episodeState(for: episode, in: context) ?? makeEpisodeState(for: episode, in: context)

        // Already a local file — mark downloaded silently, no HUD, no event
        if remoteURL.isFileURL, FileManager.default.fileExists(atPath: remoteURL.path) {
            state.downloadedFileURL = remoteURL
            state.isDownloaded = true
            try? context.save()
            Task { try? await BackendClient().requestArtifacts(for: episode.stableID) }
            return true
        }

        // Already in cache — mark downloaded silently, no HUD, no event
        if let cachedURL = await LocalMediaCache.existingCachedFileURL(for: remoteURL) {
            state.downloadedFileURL = cachedURL
            state.isDownloaded = true
            try? context.save()
            Task { try? await BackendClient().requestArtifacts(for: episode.stableID) }
            return true
        }

        // Actual network download — show HUD and log
        let progressID = progressID ?? episode.stableID
        await MainActor.run { DownloadProgressCenter.shared.begin(id: progressID, title: episode.title) }
        do {
            let localURL = try await LocalMediaCache.cachedOrDownload(remoteURL, progressID: progressID)
            state.downloadedFileURL = localURL
            state.isDownloaded = true
            try? context.save()
            Task { try? await BackendClient().requestArtifacts(for: episode.stableID) }
            Task { @MainActor in EventLogger.shared?.log(kind: AppEvent.Kind.download, episode: episode) }
            return true
        } catch {
            await MainActor.run { DownloadProgressCenter.shared.fail(id: progressID) }
            #if DEBUG
            print("[PodcastsDebug][Download] failed id=\(episode.stableID) url=\(episode.audioURL) error=\(error)")
            #endif
            return false
        }
    }

    static func playableDownloadedEpisode(for episode: EpisodeDTO, in context: ModelContext, progressID: String? = nil) async -> EpisodeDTO? {
        if let downloadedEpisode = downloadedEpisode(for: episode, in: context) { return downloadedEpisode }

        guard await downloadAudio(for: episode, in: context, progressID: progressID) else {
            return nil
        }
        let state = episodeState(for: episode, in: context) ?? makeEpisodeState(for: episode, in: context)
        guard state.isDownloaded,
              let downloadedFileURL = state.downloadedFileURL,
              FileManager.default.fileExists(atPath: downloadedFileURL.path) else {
            return nil
        }
        return state.episodeDTO(preferDownloadedFile: true)
    }

    static func downloadedEpisode(for episode: EpisodeDTO, in context: ModelContext) -> EpisodeDTO? {
        if let state = episodeState(for: episode, in: context) {
            guard state.isDownloaded,
                  let downloadedFileURL = state.downloadedFileURL,
                  FileManager.default.fileExists(atPath: downloadedFileURL.path) else {
                return nil
            }
            return state.episodeDTO(preferDownloadedFile: true)
        }
        // No state record — fall back to checking if audioURL is already a local file
        if let url = URL(string: episode.audioURL), url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
            return episode
        }
        return nil
    }

    static func removeDownload(for episode: EpisodeDTO, in context: ModelContext) {
        Task { await LocalMediaCache.cancelDownloads(progressIDs: [episode.stableID, "policy-\(episode.stableID)"]) }
        let state = episodeState(for: episode, in: context) ?? makeEpisodeState(for: episode, in: context)
        let localURL = state.downloadedFileURL
        state.downloadedFileURL = nil
        state.isDownloaded = false
        if let localURL {
            Task { await LocalMediaCache.removeFileIfPresent(at: localURL) }
        }
        try? context.save()
        Task { @MainActor in EventLogger.shared?.log(kind: AppEvent.Kind.deleteDownload, episode: episode) }
    }

    static func removeDownloads(for episodes: [EpisodeDTO], in context: ModelContext) {
        episodes.forEach { removeDownload(for: $0, in: context) }
    }

    static func downloadPolicyTargets(for episodes: [EpisodeDTO], policy: EpisodeDownloadPolicy, in context: ModelContext) -> [EpisodeDTO] {
        let visible = visibleEpisodes(episodes, in: context)
        switch policy {
        case .manual:
            return []
        case .latest:
            return Array(visible.prefix(1))
        case .unplayed:
            return unplayedEpisodes(visible, in: context)
        case .all:
            return visible
        }
    }

    @MainActor
    static func downloadPolicyTargets(for episodes: [EpisodeDTO], subscription: PodcastSubscription?, in context: ModelContext) -> [EpisodeDTO] {
        downloadPolicyTargets(for: episodes, policy: DownloadSettings.policy(for: subscription), in: context)
    }

    static func applyDownloadPolicy(to episodes: [EpisodeDTO], policy: EpisodeDownloadPolicy, in context: ModelContext) async -> Int {
        let targets = downloadPolicyTargets(for: episodes, policy: policy, in: context)
        let downloadedIDs = downloadedEpisodeIDs(for: targets, in: context)
        var completed = 0
        for episode in targets where !downloadedIDs.contains(episode.stableID) {
            if await downloadAudio(for: episode, in: context, progressID: "policy-\(episode.stableID)") {
                completed += 1
            }
            await Task.yield()
        }
        return completed
    }

    @MainActor
    static func applyDownloadPolicy(to episodes: [EpisodeDTO], subscription: PodcastSubscription?, in context: ModelContext) async -> Int {
        let targets = downloadPolicyTargets(for: episodes, subscription: subscription, in: context)
        let downloadedIDs = downloadedEpisodeIDs(for: targets, in: context)
        var completed = 0
        for episode in targets where !downloadedIDs.contains(episode.stableID) {
            if await downloadAudio(for: episode, in: context, progressID: "policy-\(episode.stableID)") {
                completed += 1
            }
            await Task.yield()
        }
        return completed
    }

    static func downloadedEpisodeIDs(for episodes: [EpisodeDTO], in context: ModelContext) -> Set<String> {
        let episodeIDs = Set(episodes.map(\.stableID))
        guard !episodeIDs.isEmpty else { return [] }
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? context.fetch(descriptor)) ?? []
        return Set(states.compactMap { state in
            episodeIDs.contains(state.episodeStableID) && state.isDownloaded ? state.episodeStableID : nil
        })
    }

    static func markAllPlayed(_ episodes: [EpisodeDTO], in context: ModelContext) {
        visibleEpisodes(episodes, in: context).forEach { markPlayed($0, in: context) }
    }

    static func markAllUnplayed(_ episodes: [EpisodeDTO], in context: ModelContext) {
        visibleEpisodes(episodes, in: context).forEach { markUnplayed($0, in: context) }
    }

    static func restoreDeletedEpisodes(forPodcastID podcastID: String, in context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? context.fetch(descriptor)) ?? []
        let matching = states.filter { $0.podcastStableID == podcastID && $0.isDeleted }
        matching.forEach {
            $0.isDeleted = false
            $0.deletedAt = nil
        }
        try? context.save()
        return matching.count
    }

    static func visibleEpisodes(_ episodes: [EpisodeDTO], in context: ModelContext) -> [EpisodeDTO] {
        let deletedIDs = episodeIDSets(for: episodes, in: context).deleted
        return episodes.filter { !deletedIDs.contains($0.stableID) }
    }

    static func unplayedEpisodes(_ episodes: [EpisodeDTO], in context: ModelContext) -> [EpisodeDTO] {
        let sets = episodeIDSets(for: episodes, in: context)
        return episodes.filter { !sets.deleted.contains($0.stableID) && !sets.played.contains($0.stableID) }
    }

    static func playedEpisodeIDs(for episodes: [EpisodeDTO], in context: ModelContext) -> Set<String> {
        episodeIDSets(for: episodes, in: context).played
    }

    static func deletedEpisodeIDs(for episodes: [EpisodeDTO], in context: ModelContext) -> Set<String> {
        episodeIDSets(for: episodes, in: context).deleted
    }

    static func episodeIDSets(for episodes: [EpisodeDTO], in context: ModelContext) -> (played: Set<String>, deleted: Set<String>, downloaded: Set<String>) {
        let episodeIDs = Set(episodes.map(\.stableID))
        guard !episodeIDs.isEmpty else { return ([], [], []) }
        // SwiftData cannot translate Array.contains into a SQL IN clause — it falls back to
        // fetching all rows and evaluating the predicate in-process (O(N×M)). Fetching all
        // LocalEpisodeState rows explicitly and filtering with a Set is faster.
        let states = (try? context.fetch(FetchDescriptor<LocalEpisodeState>())) ?? []
        var played: Set<String> = []
        var deleted: Set<String> = []
        var downloaded: Set<String> = []

        for state in states where episodeIDs.contains(state.episodeStableID) {
            if state.isDeleted {
                deleted.insert(state.episodeStableID)
            }
            if state.isDownloaded {
                downloaded.insert(state.episodeStableID)
            }
            if let duration = state.duration, duration > 0 {
                if state.playbackPosition >= max(0, duration - 30) {
                    played.insert(state.episodeStableID)
                }
            } else if state.lastListenedAt != nil {
                played.insert(state.episodeStableID)
            }
        }

        return (played, deleted, downloaded)
    }

    struct EpisodeDisplayData {
        let playedIDs: Set<String>
        let deletedIDs: Set<String>
        let downloadedIDs: Set<String>
        let summarySnippets: [String: String]
        let artworkURLs: [String: URL]
    }

    // Single-pass replacement for separate episodeIDSets + summarySnippets + artworkURLs calls.
    // Two targeted fetches instead of three full-table scans.
    static func episodeDisplayData(for episodes: [EpisodeDTO], in context: ModelContext) -> EpisodeDisplayData {
        episodeDisplayData(for: episodes, states: allEpisodeStates(in: context), in: context)
    }

    static func episodeDisplayData(for episodes: [EpisodeDTO], states allStates: [LocalEpisodeState], in context: ModelContext) -> EpisodeDisplayData {
        guard !episodes.isEmpty else {
            return EpisodeDisplayData(playedIDs: [], deletedIDs: [], downloadedIDs: [], summarySnippets: [:], artworkURLs: [:])
        }
        let episodeIDSet = Set(episodes.map(\.stableID))
        let podcastIDs = Array(Set(episodes.compactMap(\.podcastStableID)))

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
            let allSubs = (try? context.fetch(FetchDescriptor<PodcastSubscription>())) ?? []
            for sub in allSubs.filter({ pidSet.contains($0.stableID) }) {
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

        return EpisodeDisplayData(playedIDs: played, deletedIDs: deleted, downloadedIDs: downloaded,
                                  summarySnippets: snippets, artworkURLs: artworkURLs)
    }

    static func summarySnippets(for episodes: [EpisodeDTO], in context: ModelContext) -> [String: String] {
        let episodeIDs = Set(episodes.map(\.stableID))
        guard !episodeIDs.isEmpty else { return [:] }
        let allStates = (try? context.fetch(FetchDescriptor<LocalEpisodeState>())) ?? []
        // Duplicate LocalEpisodeState rows for one episode can exist (CloudKit
        // sync / concurrent caching), so tolerate duplicate keys instead of
        // trapping; any non-empty snippet is equivalent.
        return Dictionary(
            allStates.compactMap { state -> (String, String)? in
                guard episodeIDs.contains(state.episodeStableID),
                      let snippet = state.strippedSummary, !snippet.isEmpty else { return nil }
                return (state.episodeStableID, snippet)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    static func localEpisode(for episode: EpisodeDTO, in context: ModelContext) -> EpisodeDTO {
        episodeState(for: episode, in: context)?.episodeDTO(preferDownloadedFile: true) ?? episode
    }

    static func allEpisodeStates(in context: ModelContext) -> [LocalEpisodeState] {
        (try? context.fetch(FetchDescriptor<LocalEpisodeState>())) ?? []
    }

    static func localEpisodes(forPodcastIDs podcastIDs: [String], in context: ModelContext) -> [EpisodeDTO] {
        localEpisodes(forPodcastIDs: podcastIDs, states: allEpisodeStates(in: context))
    }

    static func localEpisodes(forPodcastIDs podcastIDs: [String], states: [LocalEpisodeState]) -> [EpisodeDTO] {
        guard !podcastIDs.isEmpty else { return [] }
        return states
            .filter { !$0.isDeleted && podcastIDs.contains($0.podcastStableID) && $0.cachedAt != nil }
            .map { $0.episodeDTO(preferDownloadedFile: true) }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    static func episodeSortIndices(in context: ModelContext) -> [String: Int] {
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? context.fetch(descriptor)) ?? []
        return states.reduce(into: [:]) { dict, state in
            if let idx = state.sortIndex { dict[state.episodeStableID] = idx }
        }
    }

    static func clearEpisodeOrder(in context: ModelContext) {
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? context.fetch(descriptor)) ?? []
        states.forEach { $0.sortIndex = nil }
        try? context.save()
    }

    static func setEpisodeOrder(_ orderedStableIDs: [String], in context: ModelContext) {
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? context.fetch(descriptor)) ?? []
        let statesByID = Dictionary(states.map { ($0.episodeStableID, $0) }, uniquingKeysWith: { first, _ in first })
        // Clear old indices first so removed episodes don't interfere
        states.forEach { $0.sortIndex = nil }
        for (index, id) in orderedStableIDs.enumerated() {
            statesByID[id]?.sortIndex = index
        }
        try? context.save()
    }

    static func localEpisodes(matching query: String, in context: ModelContext) -> [EpisodeDTO] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? context.fetch(descriptor)) ?? []
        return states
            .filter {
                !$0.isDeleted
                    && $0.cachedAt != nil
                    && ($0.title.lowercased().contains(trimmed) || ($0.summary?.lowercased().contains(trimmed) ?? false))
            }
            .map { $0.episodeDTO(preferDownloadedFile: true) }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    static func cacheEpisodes(_ episodes: [EpisodeDTO], in context: ModelContext) async {
        let preparedEpisodes = await EpisodeDataProcessor.prepare(episodes)
        let statesByID = existingEpisodeStates(for: preparedEpisodes.map(\.episode.stableID), in: context)
        for preparedEpisode in preparedEpisodes {
            applyPreparedEpisode(preparedEpisode, existingState: statesByID[preparedEpisode.episode.stableID], in: context)
        }
    }

    static func cacheEpisode(_ episode: EpisodeDTO, in context: ModelContext) async {
        guard let preparedEpisode = await EpisodeDataProcessor.prepare([episode]).first else { return }
        applyPreparedEpisode(preparedEpisode, existingState: episodeState(for: episode, in: context), in: context)
    }

    private static func applyPreparedEpisode(_ preparedEpisode: PreparedEpisode, existingState: LocalEpisodeState?, in context: ModelContext) {
        let episode = preparedEpisode.episode
        let state = existingState ?? makeEpisodeState(for: episode, in: context)
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

    private static func existingEpisodeStates(for episodeIDs: [String], in context: ModelContext) -> [String: LocalEpisodeState] {
        let wantedIDs = Set(episodeIDs)
        guard !wantedIDs.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? context.fetch(descriptor)) ?? []
        return Dictionary(
            states.compactMap { state -> (String, LocalEpisodeState)? in
                wantedIDs.contains(state.episodeStableID) ? (state.episodeStableID, state) : nil
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    static func prefetchDetails(for episodes: [EpisodeDTO], client: BackendClient, in context: ModelContext) async {
        for episode in episodes.prefix(30) {
            await cacheEpisode(episode, in: context)
            await prefetchImage(for: episode, in: context)
            await prefetchArtifacts(for: episode, client: client, in: context)
            await Task.yield()
        }
    }

    static func localArtworkURL(for episode: EpisodeDTO, in context: ModelContext) -> URL? {
        if let cached = episodeState(for: episode, in: context)?.cachedImageFileURL {
            return cached
        }
        return episode.imageURL.flatMap(URL.init) ?? showArtworkURL(for: episode, in: context)
    }

    static func artworkURLs(for episodes: [EpisodeDTO], in context: ModelContext) -> [String: URL] {
        guard !episodes.isEmpty else { return [:] }
        let episodeIDs = Set(episodes.map(\.stableID))
        let podcastIDs = Set(episodes.compactMap(\.podcastStableID))

        let stateDescriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? context.fetch(stateDescriptor)) ?? []
        var cachedImageURLs: [String: URL] = [:]
        for state in states where episodeIDs.contains(state.episodeStableID) {
            if let cached = state.cachedImageFileURL {
                cachedImageURLs[state.episodeStableID] = cached
            }
        }

        var podcastArtworkByID: [String: URL] = [:]
        if !podcastIDs.isEmpty {
            let subscriptionDescriptor = FetchDescriptor<PodcastSubscription>()
            let subscriptions = (try? context.fetch(subscriptionDescriptor)) ?? []
            for subscription in subscriptions where podcastIDs.contains(subscription.stableID) {
                guard let artworkURL = subscription.artworkURL else { continue }
                let cachedArtworkURL = LocalMediaCache.cachedFileURL(for: artworkURL)
                podcastArtworkByID[subscription.stableID] = FileManager.default.fileExists(atPath: cachedArtworkURL.path) ? cachedArtworkURL : artworkURL
            }
        }

        var urls: [String: URL] = [:]
        urls.reserveCapacity(episodes.count)
        for episode in episodes {
            if let cached = cachedImageURLs[episode.stableID] {
                urls[episode.stableID] = cached
            } else if let imageURL = episode.imageURL.flatMap(URL.init) {
                urls[episode.stableID] = imageURL
            } else if let podcastID = episode.podcastStableID, let fallbackArtwork = podcastArtworkByID[podcastID] {
                urls[episode.stableID] = fallbackArtwork
            }
        }
        return urls
    }

    static func cachedChapterImageURL(for chapter: EpisodeChapterDTO, episode: EpisodeDTO, in context: ModelContext) -> URL? {
        guard let data = artifact(for: episode, in: context)?.chapterImageFilesJSON,
              let mapping = try? JSONDecoder().decode([String: String].self, from: data),
              let remote = chapter.displayImageURL?.absoluteString,
              let local = mapping[remote] else {
            return nil
        }
        return URL(string: local)
    }

    static func showArtworkURL(for episode: EpisodeDTO, in context: ModelContext) -> URL? {
        guard let podcastStableID = episode.podcastStableID else { return nil }
        let descriptor = FetchDescriptor<PodcastSubscription>(predicate: #Predicate { $0.stableID == podcastStableID })
        guard let artworkURL = try? context.fetch(descriptor).first?.artworkURL else { return nil }
        let cachedArtworkURL = LocalMediaCache.cachedFileURL(for: artworkURL)
        if FileManager.default.fileExists(atPath: cachedArtworkURL.path) {
            return cachedArtworkURL
        }
        return artworkURL
    }

    static func artifact(for episode: EpisodeDTO, in context: ModelContext) -> LocalEpisodeArtifact? {
        let stableID = episode.stableID
        let descriptor = FetchDescriptor<LocalEpisodeArtifact>(predicate: #Predicate { $0.episodeStableID == stableID })
        return try? context.fetch(descriptor).first
    }

    enum TranscriptAlignmentStatus {
        case none
        case exactFile
        case extrapolated
    }

    static func transcriptAlignmentStatus(for episode: EpisodeDTO, in context: ModelContext) -> TranscriptAlignmentStatus {
        guard let a = artifact(for: episode, in: context),
              a.alignedTranscriptSegmentsJSON != nil else { return .none }
        if let sourceHash = a.alignmentSourceAudioHash,
           let backendHash = a.fingerprintAudioHash,
           sourceHash == backendHash {
            return .exactFile
        }
        return .extrapolated
    }

    static func cachedTranscriptText(for episode: EpisodeDTO, in context: ModelContext) -> String? {
        artifact(for: episode, in: context)?.transcriptText
    }

    static func cachedTranscriptVersion(for episode: EpisodeDTO, in context: ModelContext) -> LocalTranscriptVersion? {
        guard let artifact = artifact(for: episode, in: context),
              let textHash = artifact.transcriptTextHash else { return nil }
        return LocalTranscriptVersion(
            textHash: textHash,
            renditionID: artifact.transcriptRenditionID,
            model: artifact.transcriptModel,
            hasSegmentFingerprints: artifact.transcriptSegmentFingerprintsJSON?.isEmpty == false
        )
    }

    static func cachedTranscriptSegments(for episode: EpisodeDTO, in context: ModelContext) -> [TranscriptSegment] {
        guard let artifact = artifact(for: episode, in: context),
              let segmentsJSON = artifact.alignedTranscriptSegmentsJSON ?? artifact.transcriptSegmentsJSON else { return [] }
        return TranscriptRenderer.segments(from: segmentsJSON)
    }

    static func cachedChapters(for episode: EpisodeDTO, in context: ModelContext) async -> [EpisodeChapterDTO] {
        guard let chaptersJSON = artifact(for: episode, in: context)?.chaptersJSON else { return [] }
        return await ArtifactDataProcessor.renderChapters(chaptersJSON: chaptersJSON)
    }

    static func embeddedChapters(for episode: EpisodeDTO, in context: ModelContext) async -> [EpisodeChapterDTO] {
        if let artifact = artifact(for: episode, in: context),
           let source = artifact.chaptersSource?.lowercased(),
           source.contains("id3") || source.contains("chap"),
           let chaptersJSON = artifact.chaptersJSON {
            let cached = await ArtifactDataProcessor.renderChapters(chaptersJSON: chaptersJSON)
            let sourceIsCurrentEmbeddedParser = source.contains(embeddedChapterSource)
            if cached.count > 1, sourceIsCurrentEmbeddedParser { return cached }
        }

        let episode = localEpisode(for: episode, in: context)
        guard let audioURL = URL(string: episode.audioURL) else { return [] }
        let chapters = await EmbeddedChapterLoader.chapters(from: audioURL)
        if chapters.count > 1,
           let data = try? JSONEncoder().encode(chapters),
           let chaptersJSON = String(data: data, encoding: .utf8) {
            cacheChapters(ChapterArtifactDTO(id: nil, source: embeddedChapterSource, chaptersJSON: chaptersJSON), for: episode, in: context)
        }
        return chapters
    }

    static func cacheTranscript(_ transcript: TranscriptArtifactDTO, for episode: EpisodeDTO, in context: ModelContext) async {
        let artifact = artifact(for: episode, in: context) ?? makeArtifact(for: episode, in: context)
        artifact.transcriptSegmentsJSON = transcript.segmentsJSON
        artifact.transcriptText = await ArtifactDataProcessor.renderTranscript(segmentsJSON: transcript.segmentsJSON)
        artifact.transcriptLocale = transcript.locale
        artifact.transcriptModel = transcript.model
        artifact.transcriptTextHash = transcript.textHash
        artifact.transcriptRenditionID = transcript.renditionID
        artifact.transcriptSegmentFingerprintsJSON = transcript.segmentFingerprintsJSON
        artifact.alignedTranscriptSegmentsJSON = nil
        artifact.alignmentSourceAudioHash = nil
        artifact.alignmentHasUnmatchedSegments = false
        artifact.updatedAt = .now
    }

    static func cacheFingerprint(_ fingerprint: AudioFingerprintDTO, for episode: EpisodeDTO, in context: ModelContext) {
        let artifact = artifact(for: episode, in: context) ?? makeArtifact(for: episode, in: context)
        artifact.fingerprintAlgorithm = fingerprint.algorithm
        artifact.fingerprintChunksJSON = fingerprint.chunksJSON
        artifact.fingerprintAudioHash = fingerprint.audioHash
        artifact.updatedAt = .now
    }

    static func alignTranscriptToDownloadedAudio(for episode: EpisodeDTO, in context: ModelContext) async {
        guard let artifact = artifact(for: episode, in: context),
              artifact.alignedTranscriptSegmentsJSON == nil || artifact.alignmentAlgorithmVersion != TranscriptAligner.algorithmVersion,
              let transcriptSegmentsJSON = artifact.transcriptSegmentsJSON,
              let fingerprintAlgorithm = artifact.fingerprintAlgorithm,
              let fingerprintChunksJSON = artifact.fingerprintChunksJSON,
              let localURL = episodeState(for: episode, in: context)?.downloadedFileURL,
              FileManager.default.fileExists(atPath: localURL.path) else {
            return
        }
        let segmentFingerprintsJSON = artifact.transcriptSegmentFingerprintsJSON
        let renditionID = artifact.transcriptRenditionID
        let audioHash = artifact.fingerprintAudioHash
        do {
            let localFingerprint = try await AudioFingerprintMaker.fingerprint(audioFile: localURL)
            let backendFingerprint = AudioFingerprintDTO(
                id: nil,
                renditionID: renditionID,
                algorithm: fingerprintAlgorithm,
                chunkDuration: AudioFingerprintMaker.chunkDuration,
                chunksJSON: fingerprintChunksJSON,
                audioHash: audioHash
            )
            if let result = await runAlignment(
                transcriptSegmentsJSON: transcriptSegmentsJSON,
                segmentFingerprintsJSON: segmentFingerprintsJSON,
                backendFingerprint: backendFingerprint,
                localFingerprint: localFingerprint
            ) {
                artifact.alignedTranscriptSegmentsJSON = result.json
                artifact.alignmentSourceAudioHash = localFingerprint.renditionID
                artifact.alignmentHasUnmatchedSegments = result.hasUnmatchedSegments
                artifact.alignmentAlgorithmVersion = TranscriptAligner.algorithmVersion
                artifact.updatedAt = .now
            }
        } catch {
            // Alignment is best-effort; fall back to backend timestamps.
        }
    }

    @concurrent
    private static func runAlignment(
        transcriptSegmentsJSON: String,
        segmentFingerprintsJSON: String?,
        backendFingerprint: AudioFingerprintDTO,
        localFingerprint: AudioFingerprintUpload
    ) async -> TranscriptAlignmentResult? {
        TranscriptAligner.alignedSegmentsJSON(
            transcriptSegmentsJSON: transcriptSegmentsJSON,
            segmentFingerprintsJSON: segmentFingerprintsJSON,
            backendFingerprint: backendFingerprint,
            localFingerprint: localFingerprint
        )
    }

    static func cacheChapters(_ chapters: ChapterArtifactDTO, for episode: EpisodeDTO, in context: ModelContext) {
        let artifact = artifact(for: episode, in: context) ?? makeArtifact(for: episode, in: context)
        if prefersExistingChapters(existingSource: artifact.chaptersSource, incomingSource: chapters.source) {
            return
        }
        artifact.chaptersJSON = chapters.chaptersJSON
        artifact.chaptersSource = chapters.source
        artifact.updatedAt = .now
    }

    private static func prefersExistingChapters(existingSource: String?, incomingSource: String) -> Bool {
        guard let existingSource else { return false }
        let existing = existingSource.lowercased()
        let incoming = incomingSource.lowercased()
        let existingIsGenerated = existing.contains("generated") || existing.contains("model") || existing.contains("llm")
        let incomingIsEmbedded = incoming.contains("feed") || incoming.contains("embedded") || incoming.contains("podcast") || incoming.contains("psc") || incoming.contains("id3") || incoming.contains("chap")
        if existingIsGenerated && incomingIsEmbedded { return false }
        let existingIsEmbedded = existing.contains("feed") || existing.contains("embedded") || existing.contains("podcast") || existing.contains("psc") || existing.contains("id3") || existing.contains("chap")
        let incomingIsGenerated = incoming.contains("generated") || incoming.contains("model") || incoming.contains("llm")
        return existingIsEmbedded && incomingIsGenerated
    }

    private static func makeEpisodeState(for episode: EpisodeDTO, in context: ModelContext) -> LocalEpisodeState {
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
        context.insert(state)
        return state
    }

    private static func makeArtifact(for episode: EpisodeDTO, in context: ModelContext) -> LocalEpisodeArtifact {
        let artifact = LocalEpisodeArtifact(episodeStableID: episode.stableID)
        context.insert(artifact)
        return artifact
    }

    private static func subscription(stableID: String, in context: ModelContext) -> PodcastSubscription? {
        let descriptor = FetchDescriptor<PodcastSubscription>(predicate: #Predicate { $0.stableID == stableID })
        return try? context.fetch(descriptor).first
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func prefetchArtwork(for artworkURL: URL?) {
        guard let artworkURL else { return }
        Task {
            _ = try? await LocalMediaCache.cachedOrDownload(artworkURL)
        }
    }

    private static func prefetchImage(for episode: EpisodeDTO, in context: ModelContext) async {
        guard let state = episodeState(for: episode, in: context),
              state.cachedImageFileURL == nil,
              let remoteURL = episode.imageURL.flatMap(URL.init(string:)) else {
            return
        }
        if let localURL = try? await LocalMediaCache.cachedOrDownload(remoteURL) {
            state.cachedImageFileURL = localURL
        }
    }

    private static func prefetchArtifacts(for episode: EpisodeDTO, client: BackendClient, in context: ModelContext) async {
        let existing = artifact(for: episode, in: context)
        if existing?.transcriptSegmentsJSON == nil,
           let transcript = try? await client.transcript(for: episode.stableID) {
            await cacheTranscript(transcript, for: episode, in: context)
        }
        if let fingerprint = try? await client.fingerprint(for: episode.stableID) {
            cacheFingerprint(fingerprint, for: episode, in: context)
            await alignTranscriptToDownloadedAudio(for: episode, in: context)
        }

        let artifact = artifact(for: episode, in: context) ?? makeArtifact(for: episode, in: context)
        if artifact.chaptersJSON == nil,
           let chapters = try? await client.chapters(for: episode.stableID) {
            cacheChapters(chapters, for: episode, in: context)
        }

        let chapters = await cachedChapters(for: episode, in: context)
        guard !chapters.isEmpty else { return }
        var imageFiles = await EpisodeDataProcessor.decodeChapterImageFiles(artifact.chapterImageFilesJSON)
        for chapter in chapters {
            guard let remoteURL = chapter.displayImageURL,
                  remoteURL.scheme == "http" || remoteURL.scheme == "https",
                  imageFiles[remoteURL.absoluteString] == nil else { continue }
            if let localURL = try? await LocalMediaCache.cachedOrDownload(remoteURL) {
                imageFiles[remoteURL.absoluteString] = localURL.absoluteString
                artifact.chapterImageFilesJSON = await EpisodeDataProcessor.encodeChapterImageFiles(imageFiles)
            }
            await Task.yield()
        }
    }
}

extension LocalEpisodeState {
    func episodeDTO(preferDownloadedFile: Bool) -> EpisodeDTO {
        let localAudioURL: URL?
        if preferDownloadedFile,
           isDownloaded,
           let downloadedFileURL,
           FileManager.default.fileExists(atPath: downloadedFileURL.path) {
            localAudioURL = downloadedFileURL
        } else {
            localAudioURL = nil
        }

        return EpisodeDTO(
            id: nil,
            podcastStableID: podcastStableID.isEmpty ? nil : podcastStableID,
            stableID: episodeStableID,
            title: title,
            summary: summary,
            audioURL: localAudioURL?.absoluteString ?? audioURL.absoluteString,
            imageURL: cachedImageFileURL?.absoluteString ?? imageURL?.absoluteString,
            publishedAt: publishedAt,
            duration: duration
        )
    }
}


struct LocalTranscriptVersion: Hashable {
    let textHash: String
    let renditionID: String?
    let model: String?
    let hasSegmentFingerprints: Bool

    func isCurrent(comparedTo remote: TranscriptVersionDTO) -> Bool {
        textHash == remote.textHash
            && renditionID == remote.renditionID
            && hasSegmentFingerprints == remote.hasSegmentFingerprints
    }
}
