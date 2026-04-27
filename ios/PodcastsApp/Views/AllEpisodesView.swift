import SwiftData
import SwiftUI

struct AllEpisodesView: View {
    @Binding var selectedEpisode: EpisodeDTO?
    @Query(sort: \PodcastSubscription.sortIndex) private var subscriptions: [PodcastSubscription]
    @State private var playlists = ["Latest", "In Progress", "Downloaded", "Starred"]
    @State private var episodes: [EpisodeDTO] = []
    @State private var path: [EpisodeDTO] = []
    @State private var errorMessage: String?
    private let client = BackendClient()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Playlists") {
                    ForEach(playlists, id: \.self) { playlist in
                        NavigationLink(playlist) {
                            EpisodeListView(title: playlist, subscriptions: playlist == "Latest" ? subscriptions : [])
                        }
                    }
                    .onMove { from, to in playlists.move(fromOffsets: from, toOffset: to) }
                }

                Section("Latest From Your Library") {
                    ForEach(episodes) { episode in
                        EpisodeRow(episode: episode)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("All Episodes")
            .navigationDestination(for: EpisodeDTO.self) { episode in
                EpisodeDetailView(episode: episode)
            }
            .toolbar {
                EditButton()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
            }
            .onChange(of: selectedEpisode) { _, episode in
                guard let episode else { return }
                path = [episode]
                selectedEpisode = nil
            }
            .task(id: subscriptions.map(\.stableID)) { await load() }
            .overlay {
                if subscriptions.isEmpty {
                    ContentUnavailableView("No Subscriptions", systemImage: "square.stack", description: Text("Search for podcasts and add them to your library."))
                }
            }
            .alert("Backend error", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: { Text(errorMessage ?? "") })
        }
    }

    private func load() async {
        guard !subscriptions.isEmpty else {
            episodes = []
            return
        }
        do {
            let nested = try await withThrowingTaskGroup(of: [EpisodeDTO].self) { group in
                for subscription in subscriptions {
                    let podcastID = subscription.stableID
                    group.addTask { try await client.episodes(for: podcastID) }
                }
                var output: [[EpisodeDTO]] = []
                for try await podcastEpisodes in group { output.append(podcastEpisodes) }
                return output
            }
            episodes = nested
                .flatMap { $0 }
                .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        } catch { errorMessage = error.localizedDescription }
    }
}
