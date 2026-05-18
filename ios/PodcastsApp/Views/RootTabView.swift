import Combine
import SwiftData
import UIKit

final class RootTabController: UITabBarController {
    private let modelContext: ModelContext
    private let player: PlayerController
    private let miniPlayer: MiniPlayerView
    private var miniPlayerAccessory: UITabAccessory?
    private var isMiniPlayerSuppressed = false
    private var predownloadInFlight: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []

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
                self.player.play(playableEpisode, at: 0, artworkURL: LibraryStore.localArtworkURL(for: playableEpisode, in: self.modelContext))
                if upcoming.count > 1 {
                    self.predownload(episode: upcoming[1])
                }
                return
            }

            Task { [weak self] in
                guard let self,
                      let playableEpisode = await LibraryStore.playableDownloadedEpisode(for: nextEpisode, in: self.modelContext) else { return }
                self.player.play(playableEpisode, at: 0, artworkURL: LibraryStore.localArtworkURL(for: playableEpisode, in: self.modelContext))
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
        let episodes = LibraryStore.visibleEpisodes(LibraryStore.localEpisodes(forPodcastIDs: podcastIDs, in: modelContext), in: modelContext)
        let playedIDs = LibraryStore.playedEpisodeIDs(for: episodes, in: modelContext)
        let unplayed = episodes.filter { $0.stableID != episode.stableID && !playedIDs.contains($0.stableID) }
        guard !unplayed.isEmpty else { return [] }
        if let currentIndex = episodes.firstIndex(where: { $0.stableID == episode.stableID }) {
            let laterInList = episodes[(currentIndex + 1)...].filter { candidate in
                candidate.stableID != episode.stableID && !playedIDs.contains(candidate.stableID)
            }
            if !laterInList.isEmpty { return Array(laterInList.prefix(limit)) }
        }
        return Array(unplayed.prefix(limit))
    }

    private func predownloadNextEpisodeIfNeeded(current episode: EpisodeDTO, elapsed: TimeInterval, duration: TimeInterval?) {
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

    private func presentNowPlaying() {
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
    }
}
