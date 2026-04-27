import SwiftUI

struct AllEpisodesView: View {
    @State private var playlists = ["Latest", "In Progress", "Downloaded", "Starred"]
    @State private var episodes: [EpisodeDTO] = []
    @State private var errorMessage: String?
    private let client = BackendClient()

    var body: some View {
        NavigationStack {
            List {
                Section("Playlists") {
                    ForEach(playlists, id: \.self) { playlist in
                        NavigationLink(playlist) {
                            EpisodeListView(title: playlist, mode: playlist == "Latest" ? .all : .placeholder)
                        }
                    }
                    .onMove { from, to in playlists.move(fromOffsets: from, toOffset: to) }
                }

                Section("Latest Episodes") {
                    ForEach(episodes) { episode in
                        EpisodeRow(episode: episode)
                    }
                }
            }
            .navigationTitle("All Episodes")
            .toolbar {
                EditButton()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
            }
            .task { await load() }
            .alert("Backend error", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: { Text(errorMessage ?? "") })
        }
    }

    private func load() async {
        do { episodes = try await client.allEpisodes() } catch { errorMessage = error.localizedDescription }
    }
}
