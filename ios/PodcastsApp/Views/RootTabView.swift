import Combine
import SwiftData
import UIKit

final class RootTabController: UITabBarController {
    private let modelContext: ModelContext
    private let player: PlayerController
    private let miniPlayer: MiniPlayerView
    private var miniPlayerAccessory: UITabAccessory?
    private var isMiniPlayerSuppressed = false
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

    private func observePlaybackPersistence() {
        player.$elapsed
            .combineLatest(player.$duration, player.$currentEpisode)
            .throttle(for: .seconds(5), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] elapsed, duration, episode in
                guard let self, let episode else { return }
                LibraryStore.updatePlaybackState(episode: episode, elapsed: elapsed, duration: duration, in: self.modelContext)
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
