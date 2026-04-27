import SwiftUI

struct RootTabView: View {
    @StateObject private var player = PlayerController()

    var body: some View {
        TabView {
            AllEpisodesView()
                .tabItem { Label("Episodes", systemImage: "list.bullet") }
            AllPodcastsView()
                .tabItem { Label("Podcasts", systemImage: "square.stack") }
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
        }
        .environmentObject(player)
        .safeAreaInset(edge: .bottom) {
            MiniPlayerView()
                .environmentObject(player)
        }
    }
}
