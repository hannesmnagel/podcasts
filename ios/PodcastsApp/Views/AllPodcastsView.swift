import SwiftUI

struct AllPodcastsView: View {
    @State private var podcasts: [PodcastDTO] = []
    @State private var feedURL = ""
    @State private var errorMessage: String?
    private let client = BackendClient()

    var body: some View {
        NavigationStack {
            List {
                Section("Add Feed") {
                    TextField("RSS feed URL", text: $feedURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button("Add Podcast", action: addPodcast)
                        .disabled(URL(string: feedURL) == nil)
                }

                Section("Podcasts") {
                    ForEach(podcasts) { podcast in
                        NavigationLink(podcast.title.isEmpty ? podcast.feedURL : podcast.title) {
                            EpisodeListView(title: podcast.title, podcastID: podcast.stableID)
                        }
                    }
                }
            }
            .navigationTitle("All Podcasts")
            .task { await load() }
            .alert("Backend error", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "")
            })
        }
    }

    private func load() async {
        do { podcasts = try await client.podcasts() } catch { errorMessage = error.localizedDescription }
    }

    private func addPodcast() {
        guard let url = URL(string: feedURL) else { return }
        Task {
            do {
                _ = try await client.addPodcast(feedURL: url)
                feedURL = ""
                await load()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
