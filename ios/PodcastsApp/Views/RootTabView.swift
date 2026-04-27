import SwiftUI

struct RootTabView: View {
    private enum AppTab {
        case episodes
        case podcasts
        case search
    }

    @StateObject private var player = PlayerController()
    @State private var showNowPlaying = false
    @State private var selectedTab: AppTab = .episodes
    @State private var selectedEpisode: EpisodeDTO?
    @State private var selectedPodcastID: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            AllEpisodesView(selectedEpisode: $selectedEpisode)
                .tabItem { Label("Episodes", systemImage: "list.bullet") }
                .tag(AppTab.episodes)
            AllPodcastsView(selectedPodcastID: $selectedPodcastID)
                .tabItem { Label("Podcasts", systemImage: "square.stack") }
                .tag(AppTab.podcasts)
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppTab.search)
        }
        .tabViewBottomAccessory(isEnabled: player.currentEpisode != nil) {
            MiniPlayerView(showNowPlaying: $showNowPlaying)
                .environmentObject(player)
        }
        .environmentObject(player)
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView(
                showEpisodeDetails: showEpisodeDetails,
                showPodcast: showPodcast
            )
                .environmentObject(player)
        }
    }

    private func showEpisodeDetails(_ episode: EpisodeDTO) {
        showNowPlaying = false
        selectedTab = .episodes
        selectedEpisode = episode
    }

    private func showPodcast(_ episode: EpisodeDTO) {
        guard let podcastStableID = episode.podcastStableID else { return }
        showNowPlaying = false
        selectedTab = .podcasts
        selectedPodcastID = podcastStableID
    }
}
