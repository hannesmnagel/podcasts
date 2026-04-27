import SwiftUI

struct RootTabView: View {
    @StateObject private var player = PlayerController()
    @State private var showNowPlaying = false

    var body: some View {
        TabView {
            AllEpisodesView()
                .tabItem { Label("Episodes", systemImage: "list.bullet") }
            AllPodcastsView()
                .tabItem { Label("Podcasts", systemImage: "square.stack") }
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
        }
        .tabViewBottomAccessory(isEnabled: player.currentEpisode != nil) {
            MiniPlayerView(showNowPlaying: $showNowPlaying)
                .environmentObject(player)
        }
        .environmentObject(player)
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView()
                .environmentObject(player)
        }
    }
}
