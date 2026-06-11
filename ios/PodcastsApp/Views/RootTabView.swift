import Combine
import PodcatcherKit
import SwiftData
import UIKit
import WidgetKit

final class RootTabController: UITabBarController {
    private let modelContext: ModelContext
    private let player: PlayerController
    private let miniPlayer: MiniPlayerView
    private var miniPlayerAccessory: UITabAccessory?
    private var isMiniPlayerSuppressed = false
    private var predownloadInFlight: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []
    private let sharedStateWriter = SharedStateWriter()
    private let liveActivity = LiveActivityController()
    private var currentArtworkURL: URL?
    private var sharedArtworkURL: URL?
    private var currentPodcastTitle: String = ""

    private lazy var episodesController = AllEpisodesViewController(modelContext: modelContext, player: player)
    private lazy var podcastsController = AllPodcastsViewController(modelContext: modelContext, player: player)
    private lazy var searchController = SearchViewController(modelContext: modelContext, player: player)

    init(modelContext: ModelContext, player: PlayerController) {
        self.modelContext = modelContext
        self.player = player
        self.miniPlayer = MiniPlayerView(modelContext: modelContext, player: player)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tabBarMinimizeBehavior = .onScrollDown
        episodesController.tabBarItem = UITabBarItem(title: "Episodes", image: UIImage(systemName: "list.bullet"), tag: 0)
        podcastsController.tabBarItem = UITabBarItem(title: "Podcasts", image: UIImage(systemName: "square.stack"), tag: 1)
        searchController.tabBarItem = UITabBarItem(tabBarSystemItem: .search, tag: 2)

        viewControllers = [
            UINavigationController(rootViewController: episodesController),
            UINavigationController(rootViewController: podcastsController),
            UINavigationController(rootViewController: searchController)
        ]
        configureMiniPlayer()
        configureAutoplayNextEpisode()
        restorePlaybackState()
        observePlaybackPersistence()
        observeSeekUndoHUD()
        observeSharedState()
        flushLibrarySnapshot()
    }

    private func configureMiniPlayer() {
        miniPlayer.openNowPlaying = { [weak self] in self?.presentNowPlaying() }
        player.$currentEpisode.receive(on: DispatchQueue.main).sink { [weak self] episode in
            self?.setMiniPlayerVisible(episode != nil && self?.isMiniPlayerSuppressed == false)
        }.store(in: &cancellables)
    }

    private func restorePlaybackState() {
        guard player.currentEpisode == nil,
              let episode = LibraryStore.lastPlaybackEpisode(in: modelContext) else {
            return
        }
        let position = LibraryStore.playbackPosition(for: episode, in: modelContext)
        player.restore(episode, at: position, artworkURL: LibraryStore.localArtworkURL(for: episode, in: modelContext))
    }

    private func configureAutoplayNextEpisode() {
        player.playbackDidFinish = { [weak self] episode in
            guard let self else { return }
            LibraryStore.finishNaturalPlayback(episode, in: self.modelContext)
            let upcoming = self.nextUnplayedEpisodes(after: episode, limit: 2)
            guard let nextEpisode = upcoming.first else { return }

            if let playableEpisode = LibraryStore.downloadedEpisode(for: nextEpisode, in: self.modelContext) {
                let position = LibraryStore.playbackPosition(for: playableEpisode, in: self.modelContext)
                self.player.play(playableEpisode, at: position, artworkURL: LibraryStore.localArtworkURL(for: playableEpisode, in: self.modelContext))
                if upcoming.count > 1 {
                    self.predownload(episode: upcoming[1])
                }
                return
            }

            Task { [weak self] in
                guard let self,
                      let playableEpisode = await LibraryStore.playableDownloadedEpisode(for: nextEpisode, in: self.modelContext) else { return }
                let position = LibraryStore.playbackPosition(for: playableEpisode, in: self.modelContext)
                self.player.play(playableEpisode, at: position, artworkURL: LibraryStore.localArtworkURL(for: playableEpisode, in: self.modelContext))
                if upcoming.count > 1 {
                    self.predownload(episode: upcoming[1])
                }
            }
        }
    }

    private func nextUnplayedEpisode(after episode: EpisodeDTO) -> EpisodeDTO? {
        nextUnplayedEpisodes(after: episode, limit: 1).first
    }

    private func nextUnplayedEpisodes(after episode: EpisodeDTO, limit: Int) -> [EpisodeDTO] {
        let podcastIDs = Self.subscriptionIDs(in: modelContext)
        guard !podcastIDs.isEmpty else { return [] }
        let allEpisodes = LibraryStore.localEpisodes(forPodcastIDs: podcastIDs, in: modelContext)
        let idSets = LibraryStore.episodeIDSets(for: allEpisodes, in: modelContext)
        let episodes = allEpisodes.filter { !idSets.deleted.contains($0.stableID) }
        let playedIDs = idSets.played
        let unplayed = episodes.filter { $0.stableID != episode.stableID && !playedIDs.contains($0.stableID) }
        guard !unplayed.isEmpty else { return [] }
        if PlaybackSettings.continueWithNewestEpisode {
            return Array(unplayed.prefix(limit))
        }
        if let currentIndex = episodes.firstIndex(where: { $0.stableID == episode.stableID }) {
            let laterInList = episodes[(currentIndex + 1)...].filter { !playedIDs.contains($0.stableID) }
            if !laterInList.isEmpty { return Array(laterInList.prefix(limit)) }
        }
        return Array(unplayed.prefix(limit))
    }

    private func predownloadNextEpisodeIfNeeded(current episode: EpisodeDTO, elapsed: TimeInterval, duration: TimeInterval?) {
        guard DownloadSettings.preloadsNextEpisode else { return }
        guard let duration, duration > 0 else { return }
        let remaining = duration - elapsed
        guard remaining <= 180 else { return }
        guard let nextEpisode = nextUnplayedEpisode(after: episode) else { return }
        predownload(episode: nextEpisode)
    }

    private func predownload(episode: EpisodeDTO) {
        guard !predownloadInFlight.contains(episode.stableID) else { return }
        predownloadInFlight.insert(episode.stableID)
        Task { [weak self] in
            guard let self else { return }
            _ = await LibraryStore.playableDownloadedEpisode(for: episode, in: self.modelContext)
            self.predownloadInFlight.remove(episode.stableID)
        }
    }

    private static func subscriptionIDs(in modelContext: ModelContext) -> [String] {
        var descriptor = FetchDescriptor<PodcastSubscription>(sortBy: [SortDescriptor(\.sortIndex)])
        descriptor.includePendingChanges = true
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.stableID)
    }

    private func observePlaybackPersistence() {
        player.$elapsed
            .combineLatest(player.$duration, player.$currentEpisode)
            .throttle(for: .seconds(5), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] elapsed, duration, episode in
                guard let self, let episode else { return }
                LibraryStore.updatePlaybackState(episode: episode, elapsed: elapsed, duration: duration, in: self.modelContext)
                self.predownloadNextEpisodeIfNeeded(current: episode, elapsed: elapsed, duration: duration)
            }
            .store(in: &cancellables)
    }

    private func observeSeekUndoHUD() {
        player.$seekAction
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { action in
                UndoSeekHUD.shared.show(action: action)
            }
            .store(in: &cancellables)
    }

    private func observeSharedState() {
        player.$currentEpisode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] episode in
                guard let self else { return }
                if let episode {
                    self.currentArtworkURL = LibraryStore.localArtworkURL(for: episode, in: self.modelContext)
                    self.sharedArtworkURL = Self.artworkURLForWidget(from: self.currentArtworkURL)
                    self.currentPodcastTitle = self.podcastTitle(for: episode)
                    self.liveActivity.startOrUpdate(
                        episode: episode,
                        podcastTitle: self.currentPodcastTitle,
                        artworkFileURL: self.sharedArtworkURL,
                        isPlaying: self.player.isPlaying,
                        elapsed: self.player.elapsed,
                        duration: self.player.duration,
                        speed: Double(self.player.speed)
                    )
                } else {
                    self.currentArtworkURL = nil
                    self.sharedArtworkURL = nil
                    self.currentPodcastTitle = ""
                    self.liveActivity.end()
                }
                self.flushPlaybackState()
                WidgetCenter.shared.reloadAllTimelines()
            }
            .store(in: &cancellables)

        player.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                guard let self, let episode = self.player.currentEpisode else { return }
                self.liveActivity.startOrUpdate(
                    episode: episode,
                    podcastTitle: self.currentPodcastTitle,
                    artworkFileURL: self.sharedArtworkURL,
                    isPlaying: isPlaying,
                    elapsed: self.player.elapsed,
                    duration: self.player.duration,
                    speed: Double(self.player.speed)
                )
                self.flushPlaybackState()
                WidgetCenter.shared.reloadAllTimelines()
            }
            .store(in: &cancellables)

        player.$speed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] speed in
                guard let self, let episode = self.player.currentEpisode else { return }
                self.liveActivity.startOrUpdate(
                    episode: episode,
                    podcastTitle: self.currentPodcastTitle,
                    artworkFileURL: self.sharedArtworkURL,
                    isPlaying: self.player.isPlaying,
                    elapsed: self.player.elapsed,
                    duration: self.player.duration,
                    speed: Double(speed)
                )
                self.flushPlaybackState()
            }
            .store(in: &cancellables)

        player.$elapsed
            .throttle(for: .seconds(2), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] elapsed in
                guard let self else { return }
                self.flushPlaybackState()
                self.liveActivity.pushElapsedIfNeeded(
                    isPlaying: self.player.isPlaying,
                    elapsed: elapsed,
                    duration: self.player.duration,
                    speed: Double(self.player.speed)
                )
            }
            .store(in: &cancellables)
    }

    private func flushPlaybackState() {
        guard let episode = player.currentEpisode else {
            sharedStateWriter.writePlaybackState(SharedPlaybackState())
            return
        }
        let state = SharedPlaybackState(
            episodeStableID: episode.stableID,
            podcastStableID: episode.podcastStableID,
            title: episode.title,
            podcastTitle: currentPodcastTitle,
            artworkFileURL: sharedArtworkURL,
            isPlaying: player.isPlaying,
            elapsed: player.elapsed,
            duration: player.duration,
            speed: Double(player.speed),
            updatedAt: Date()
        )
        sharedStateWriter.writePlaybackState(state)
    }

    // Returns a file URL accessible by the widget extension (App Group container).
    // LocalMediaCache.cacheDirectory already lives in the App Group, so cached files
    // need no copying. Remote URLs are resolved through the cache.
    private static func artworkURLForWidget(from url: URL?) -> URL? {
        guard let url else { return nil }
        let fileURL: URL
        if url.isFileURL {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            fileURL = url
        } else {
            // Remote URL — check if LocalMediaCache has a copy
            let cached = LocalMediaCache.cachedFileURL(for: url)
            guard FileManager.default.fileExists(atPath: cached.path) else { return nil }
            fileURL = cached
        }
        // Hand the widget a downsampled copy — large sources blow its memory cap.
        return LocalMediaCache.widgetArtworkFileURL(for: fileURL)
    }

    func flushLibrarySnapshot() {
        let subscriptionDescriptor = FetchDescriptor<PodcastSubscription>(sortBy: [SortDescriptor(\.sortIndex)])
        let subscriptions = (try? modelContext.fetch(subscriptionDescriptor)) ?? []
        let sharedSubs = subscriptions.map { sub in
            SharedPodcastInfo(
                stableID: sub.stableID,
                title: sub.title,
                artworkFileURL: Self.artworkURLForWidget(from: sub.artworkURL)
            )
        }

        let podcastTitles = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.stableID, $0.title) })
        let subscribedPodcastIDs = Set(subscriptions.map { $0.stableID })
        func makeEpisodeInfo(_ state: LocalEpisodeState) -> SharedEpisodeInfo {
            let artworkFileURL: URL? = state.cachedImageFileURL ?? {
                guard let imageURL = state.imageURL else { return nil }
                let cached = LocalMediaCache.cachedFileURL(for: imageURL)
                return FileManager.default.fileExists(atPath: cached.path) ? cached : nil
            }()
            return SharedEpisodeInfo(
                stableID: state.episodeStableID,
                podcastStableID: state.podcastStableID,
                title: state.title,
                podcastTitle: podcastTitles[state.podcastStableID] ?? "",
                duration: state.duration,
                publishedAt: state.publishedAt,
                isPlayed: false,
                playbackPosition: state.playbackPosition,
                artworkFileURL: Self.artworkURLForWidget(from: artworkFileURL)
            )
        }

        // "Unplayed" matches the Episodes tab's two-branch rule (LibraryStore.isPlayed):
        // with a known duration, played = position ≥ duration − 30; with no known
        // duration, played = lastListenedAt != nil. Pushing the played + subscription
        // filter into the fetch (rather than filtering a fixed newest-N window
        // afterwards) means the limit counts *unplayed* episodes, so older unplayed
        // ones surface once the newer ones are played. No cachedAt requirement —
        // non-downloaded episodes are eligible too.
        func isUnplayed(_ state: LocalEpisodeState) -> Bool {
            if let duration = state.duration, duration > 0 {
                return state.playbackPosition < duration - 30
            }
            return state.lastListenedAt == nil
        }
        let subscribedIDsArray = Array(subscribedPodcastIDs)
        let episodesDescriptor = FetchDescriptor<LocalEpisodeState>(
            predicate: #Predicate { state in
                !state.isDeleted
                    && state.publishedAt != nil
                    && subscribedIDsArray.contains(state.podcastStableID)
            },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        )
        let recentEpisodes = Array(
            ((try? modelContext.fetch(episodesDescriptor)) ?? [])
                .lazy
                .filter(isUnplayed)
                .prefix(10)
                .map(makeEpisodeInfo)
        )

        var newestDescriptor = FetchDescriptor<LocalEpisodeState>(
            predicate: #Predicate { !$0.isDeleted },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        )
        newestDescriptor.fetchLimit = 10
        let newestStates = (try? modelContext.fetch(newestDescriptor)) ?? []
        let newestState = newestStates.first {
            guard subscribedPodcastIDs.contains($0.podcastStableID) else { return false }
            let d = $0.duration ?? 0
            return d <= 0 || $0.playbackPosition / d <= 0.95
        }
        let newestEpisode: SharedEpisodeInfo? = newestState.map { state in
            let artworkFileURL: URL? = state.cachedImageFileURL.flatMap {
                FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
            } ?? state.imageURL.flatMap {
                let cached = LocalMediaCache.cachedFileURL(for: $0)
                return FileManager.default.fileExists(atPath: cached.path) ? cached : nil
            }
            return SharedEpisodeInfo(
                stableID: state.episodeStableID,
                podcastStableID: state.podcastStableID,
                title: state.title,
                podcastTitle: podcastTitles[state.podcastStableID] ?? "",
                duration: state.duration,
                publishedAt: state.publishedAt,
                isPlayed: false,
                playbackPosition: state.playbackPosition,
                artworkFileURL: Self.artworkURLForWidget(from: artworkFileURL)
            )
        }

        sharedStateWriter.writeLibrarySnapshot(SharedLibrarySnapshot(
            subscriptions: sharedSubs,
            recentEpisodes: recentEpisodes,
            newestEpisode: newestEpisode,
            updatedAt: Date()
        ))
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func podcastTitle(for episode: EpisodeDTO) -> String {
        guard let podcastID = episode.podcastStableID else { return "" }
        let descriptor = FetchDescriptor<PodcastSubscription>(
            predicate: #Predicate { $0.stableID == podcastID }
        )
        return (try? modelContext.fetch(descriptor))?.first?.title ?? ""
    }

    func endLiveActivity() {
        liveActivity.end()
    }

    func persistCurrentPlaybackState() {
        guard let episode = player.currentEpisode else { return }
        LibraryStore.updatePlaybackState(episode: episode, elapsed: player.elapsed, duration: player.duration, in: modelContext)
    }

    func setMiniPlayerSuppressed(_ isSuppressed: Bool, animated: Bool) {
        guard isMiniPlayerSuppressed != isSuppressed else { return }
        isMiniPlayerSuppressed = isSuppressed
        setMiniPlayerVisible(player.currentEpisode != nil && !isSuppressed, animated: animated)
    }

    private func setMiniPlayerVisible(_ isVisible: Bool) {
        setMiniPlayerVisible(isVisible, animated: false)
    }

    private func setMiniPlayerVisible(_ isVisible: Bool, animated: Bool) {
        if isVisible {
            if miniPlayerAccessory == nil {
                miniPlayerAccessory = UITabAccessory(contentView: miniPlayer)
            }
            setBottomAccessory(miniPlayerAccessory, animated: animated)
        } else {
            setBottomAccessory(nil, animated: animated)
        }
    }

    func checkSleepRecovery() {
        guard PlaybackSettings.sleepRecoveryEnabled, SleepRecoveryService.isAvailable else { return }
        Task {
            guard let sleepOnset = await SleepRecoveryService.lastSleepOnset() else { return }
            // Only offer once per sleep session
            if let last = PlaybackSettings.lastHandledSleepOnset,
               abs(last.timeIntervalSince(sleepOnset)) < 3600 { return }
            guard let result = SleepRecoveryService.findRecovery(sleepOnset: sleepOnset, context: modelContext) else { return }
            // Don't offer if we're already at or before the target position for the same episode
            if player.currentEpisode?.stableID == result.episodeStableID,
               player.elapsed <= result.seekPosition + 60 { return }
            presentSleepRecoveryAlert(result)
        }
    }

    private func presentSleepRecoveryAlert(_ result: SleepRecoveryResult) {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let time = formatter.string(from: result.sleepOnset)
        let truncatedTitle = result.episodeTitle.count > 50
            ? String(result.episodeTitle.prefix(47)) + "…"
            : result.episodeTitle

        let undoCount = result.episodesStartedDuringSleep.count
        var message = "You fell asleep around \(time) while listening to \"\(truncatedTitle)\"."
        if undoCount > 0 {
            let plural = undoCount == 1 ? "1 episode" : "\(undoCount) episodes"
            message += " \(plural) played after that will be marked unplayed."
        }

        let alert = UIAlertController(title: "Restore Sleep Position", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Restore", style: .default) { [weak self] _ in
            guard let self else { return }
            PlaybackSettings.lastHandledSleepOnset = result.sleepOnset
            self.applySleepRecovery(result)
        })
        alert.addAction(UIAlertAction(title: "Dismiss", style: .cancel) { [weak self] _ in
            PlaybackSettings.lastHandledSleepOnset = result.sleepOnset
            _ = self  // retain
        })
        present(alert, animated: true)
    }

    private func applySleepRecovery(_ result: SleepRecoveryResult) {
        // Mark auto-advanced episodes as unplayed
        for episodeID in result.episodesStartedDuringSleep {
            let descriptor = FetchDescriptor<LocalEpisodeState>(
                predicate: #Predicate { $0.episodeStableID == episodeID }
            )
            if let state = (try? modelContext.fetch(descriptor))?.first {
                state.playbackPosition = 0
                state.lastListenedAt = nil
            }
        }
        try? modelContext.save()

        // Find and load the target episode
        let allPodcastIDs = Self.subscriptionIDs(in: modelContext)
        let episodes = LibraryStore.localEpisodes(forPodcastIDs: allPodcastIDs, in: modelContext)
        guard let episode = episodes.first(where: { $0.stableID == result.episodeStableID }) else { return }

        if let playable = LibraryStore.downloadedEpisode(for: episode, in: modelContext) {
            player.play(playable, at: result.seekPosition, artworkURL: LibraryStore.localArtworkURL(for: playable, in: modelContext))
        } else {
            Task { [weak self] in
                guard let self,
                      let playable = await LibraryStore.playableDownloadedEpisode(for: episode, in: self.modelContext) else { return }
                self.player.play(playable, at: result.seekPosition, artworkURL: LibraryStore.localArtworkURL(for: playable, in: self.modelContext))
            }
        }
    }

    func handle(deepLink url: URL) {
        guard url.scheme == "podcatcher" else { return }
        switch url.host {
        case "nowplaying":
            presentNowPlaying()
        case "episode":
            let stableID = url.pathComponents.dropFirst().first ?? ""
            guard !stableID.isEmpty else { return }
            playEpisode(stableID: stableID)
        default:
            break
        }
    }

    private func playEpisode(stableID: String) {
        let podcastIDs = Self.subscriptionIDs(in: modelContext)
        guard !podcastIDs.isEmpty else { return }
        let episodes = LibraryStore.localEpisodes(forPodcastIDs: podcastIDs, in: modelContext)
        guard let episode = episodes.first(where: { $0.stableID == stableID }) else { return }
        let position = LibraryStore.playbackPosition(for: episode, in: modelContext)
        let artworkURL = LibraryStore.localArtworkURL(for: episode, in: modelContext)
        if let playable = LibraryStore.downloadedEpisode(for: episode, in: modelContext) {
            player.play(playable, at: position, artworkURL: artworkURL)
        } else {
            Task { [weak self] in
                guard let self,
                      let playable = await LibraryStore.playableDownloadedEpisode(for: episode, in: self.modelContext) else { return }
                let pos = LibraryStore.playbackPosition(for: playable, in: self.modelContext)
                self.player.play(playable, at: pos, artworkURL: LibraryStore.localArtworkURL(for: playable, in: self.modelContext))
            }
        }
    }

    private func presentNowPlaying() {
        #if targetEnvironment(macCatalyst)
        PodcastsAppDelegate.openNowPlayingWindow()
        #else
        let nowPlaying = NowPlayingViewController(modelContext: modelContext, player: player)
        nowPlaying.modalPresentationStyle = .fullScreen
        nowPlaying.showEpisodeDetails = { [weak self, weak nowPlaying] episode in
            nowPlaying?.dismiss(animated: true)
            self?.selectedIndex = 0
            self?.episodesController.openEpisode(episode)
        }
        nowPlaying.showPodcast = { [weak self, weak nowPlaying] episode in
            guard let podcastID = episode.podcastStableID else { return }
            nowPlaying?.dismiss(animated: true)
            self?.selectedIndex = 1
            self?.podcastsController.openPodcast(podcastID)
        }
        present(nowPlaying, animated: true)
        #endif
    }
}
