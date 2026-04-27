import SwiftData
import SwiftUI

@main
struct PodcastsApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(for: [PodcastSubscription.self, LocalEpisodeState.self, Playlist.self])
    }
}
