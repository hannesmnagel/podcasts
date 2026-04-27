import SwiftData
import SwiftUI

struct SearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var subscriptions: [PodcastSubscription]
    @State private var query = ""
    @State private var results = EpisodeSearchDTO()
    @State private var errorMessage: String?
    @State private var addingFeedURL: String?
    private let client = BackendClient()

    var body: some View {
        NavigationStack {
            List {
                if !results.podcasts.isEmpty {
                    Section("Known Podcasts") {
                        ForEach(results.podcasts) { podcast in
                            SearchPodcastRow(
                                title: podcast.title.isEmpty ? podcast.feedURL : podcast.title,
                                subtitle: podcast.feedURL,
                                artworkURL: podcast.imageURL,
                                isSubscribed: isSubscribed(to: podcast.stableID),
                                isAdding: addingFeedURL == podcast.feedURL
                            ) {
                                Task { await addKnownPodcast(podcast) }
                            }
                        }
                    }
                }
                if !results.episodes.isEmpty {
                    Section("Episodes") {
                        ForEach(results.episodes) { episode in EpisodeRow(episode: episode) }
                    }
                }
                if !results.directory.isEmpty {
                    Section("Apple Podcasts Directory") {
                        ForEach(results.directory) { podcast in
                            SearchPodcastRow(
                                title: podcast.title,
                                subtitle: podcast.artistName ?? podcast.feedURL,
                                artworkURL: podcast.artworkURL,
                                isSubscribed: subscriptions.contains { $0.feedURL.absoluteString == podcast.feedURL },
                                isAdding: addingFeedURL == podcast.feedURL
                            ) {
                                Task { await addDirectoryPodcast(podcast) }
                            }
                        }
                    }
                }
            }
            .overlay {
                if query.isEmpty {
                    ContentUnavailableView("Search", systemImage: "magnifyingglass", description: Text("Search the shared podcast catalog and Apple Podcasts, then add shows to your private library."))
                } else if results.podcasts.isEmpty && results.episodes.isEmpty && results.directory.isEmpty {
                    ContentUnavailableView("No Results", systemImage: "magnifyingglass")
                }
            }
            .searchable(text: $query, prompt: "Search or add podcasts")
            .navigationTitle("Search")
            .onSubmit(of: .search) { Task { await search() } }
            .onChange(of: query) { _, newValue in
                if newValue.isEmpty { results = EpisodeSearchDTO() }
            }
            .refreshable { await search() }
            .alert("Search error", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: { Text(errorMessage ?? "") })
        }
    }

    private func search() async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { results = try await client.search(query) } catch { errorMessage = error.localizedDescription }
    }

    private func addKnownPodcast(_ podcast: PodcastDTO) async {
        addingFeedURL = podcast.feedURL
        defer { addingFeedURL = nil }
        LibraryStore.subscribe(to: podcast, in: modelContext)
    }

    private func addDirectoryPodcast(_ podcast: PodcastDirectoryDTO) async {
        guard let url = URL(string: podcast.feedURL) else { return }
        addingFeedURL = podcast.feedURL
        defer { addingFeedURL = nil }
        do {
            let addedPodcast = try await client.addPodcast(feedURL: url)
            LibraryStore.subscribe(to: addedPodcast, in: modelContext)
            await search()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isSubscribed(to stableID: String) -> Bool {
        subscriptions.contains { $0.stableID == stableID }
    }
}

private struct SearchPodcastRow: View {
    let title: String
    let subtitle: String
    let artworkURL: String?
    let isSubscribed: Bool
    let isAdding: Bool
    let add: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: artworkURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.2))
                    .overlay(Image(systemName: "waveform"))
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: add) {
                if isAdding {
                    ProgressView()
                } else {
                    Label(isSubscribed ? "Added" : "Add", systemImage: isSubscribed ? "checkmark.circle.fill" : "plus.circle.fill")
                        .labelStyle(.iconOnly)
                }
            }
            .disabled(isAdding || isSubscribed)
            .accessibilityLabel(isSubscribed ? "Already added" : "Add \(title)")
        }
    }
}
