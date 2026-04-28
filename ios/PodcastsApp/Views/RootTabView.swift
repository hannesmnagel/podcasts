import Combine
import SwiftData
import UIKit

final class RootTabController: UITabBarController {
    private let modelContext: ModelContext
    private let player: PlayerController
    private let miniPlayer: MiniPlayerView
    private var miniPlayerAccessory: UITabAccessory?
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
        episodesController.tabBarItem = UITabBarItem(title: "Episodes", image: UIImage(systemName: "list.bullet"), tag: 0)
        podcastsController.tabBarItem = UITabBarItem(title: "Podcasts", image: UIImage(systemName: "square.stack"), tag: 1)
        searchController.tabBarItem = UITabBarItem(title: "Search", image: UIImage(systemName: "magnifyingglass"), tag: 2)

        viewControllers = [
            UINavigationController(rootViewController: episodesController),
            UINavigationController(rootViewController: podcastsController),
            UINavigationController(rootViewController: searchController)
        ]
        configureMiniPlayer()
    }

    private func configureMiniPlayer() {
        miniPlayer.openNowPlaying = { [weak self] in self?.presentNowPlaying() }
        player.$currentEpisode.receive(on: DispatchQueue.main).sink { [weak self] episode in
            NSLog("[PodcastsDebug][RootTab] currentEpisode changed visible=%@", episode == nil ? "false" : "true")
            self?.setMiniPlayerVisible(episode != nil)
        }.store(in: &cancellables)
    }

    private func setMiniPlayerVisible(_ isVisible: Bool) {
        NSLog("[PodcastsDebug][RootTab] setMiniPlayerVisible %@", isVisible ? "true" : "false")
        if isVisible {
            if miniPlayerAccessory == nil {
                NSLog("[PodcastsDebug][RootTab] creating UITabAccessory")
                miniPlayerAccessory = UITabAccessory(contentView: miniPlayer)
            }
            NSLog("[PodcastsDebug][RootTab] installing UITabAccessory")
            setBottomAccessory(miniPlayerAccessory, animated: false)
        } else {
            NSLog("[PodcastsDebug][RootTab] removing UITabAccessory")
            setBottomAccessory(nil, animated: false)
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
