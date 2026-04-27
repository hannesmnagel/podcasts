import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var results = EpisodeSearchDTO(podcasts: [], episodes: [])
    @State private var errorMessage: String?
    private let client = BackendClient()

    var body: some View {
        NavigationStack {
            List {
                if !results.podcasts.isEmpty {
                    Section("Podcasts") {
                        ForEach(results.podcasts) { podcast in
                            NavigationLink(podcast.title.isEmpty ? podcast.feedURL : podcast.title) {
                                EpisodeListView(title: podcast.title, podcastID: podcast.stableID)
                            }
                        }
                    }
                }
                if !results.episodes.isEmpty {
                    Section("Episodes") {
                        ForEach(results.episodes) { episode in EpisodeRow(episode: episode) }
                    }
                }
            }
            .overlay {
                if query.isEmpty {
                    ContentUnavailableView("Search", systemImage: "magnifyingglass", description: Text("Search crawled podcasts and episodes."))
                } else if results.podcasts.isEmpty && results.episodes.isEmpty {
                    ContentUnavailableView("No Results", systemImage: "magnifyingglass")
                }
            }
            .searchable(text: $query, prompt: "Search podcasts and episodes")
            .navigationTitle("Search")
            .onSubmit(of: .search) { Task { await search() } }
            .onChange(of: query) { _, newValue in
                if newValue.isEmpty { results = EpisodeSearchDTO(podcasts: [], episodes: []) }
            }
            .alert("Search error", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: { Text(errorMessage ?? "") })
        }
    }

    private func search() async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { results = try await client.search(query) } catch { errorMessage = error.localizedDescription }
    }
}
