import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var results = EpisodeSearchDTO()
    @State private var errorMessage: String?
    @State private var addingFeedURL: String?
    private let client = BackendClient()

    var body: some View {
        NavigationStack {
            List {
                if !results.podcasts.isEmpty {
                    Section("In Library") {
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
                if !results.directory.isEmpty {
                    Section("Apple Podcasts Directory") {
                        ForEach(results.directory) { podcast in
                            PodcastDirectoryRow(podcast: podcast, isAdding: addingFeedURL == podcast.feedURL) {
                                Task { await add(podcast) }
                            }
                        }
                    }
                }
            }
            .overlay {
                if query.isEmpty {
                    ContentUnavailableView("Search", systemImage: "magnifyingglass", description: Text("Search your crawled library and Apple Podcasts to add new shows."))
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

    private func add(_ podcast: PodcastDirectoryDTO) async {
        guard let url = URL(string: podcast.feedURL) else { return }
        addingFeedURL = podcast.feedURL
        defer { addingFeedURL = nil }
        do {
            _ = try await client.addPodcast(feedURL: url)
            await search()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PodcastDirectoryRow: View {
    let podcast: PodcastDirectoryDTO
    let isAdding: Bool
    let add: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: podcast.artworkURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.2))
                    .overlay(Image(systemName: "waveform"))
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(podcast.title)
                    .font(.headline)
                    .lineLimit(2)
                if let artistName = podcast.artistName, !artistName.isEmpty {
                    Text(artistName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(podcast.feedURL)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: add) {
                if isAdding {
                    ProgressView()
                } else {
                    Label("Add", systemImage: "plus.circle.fill")
                        .labelStyle(.iconOnly)
                }
            }
            .disabled(isAdding)
            .accessibilityLabel("Add \(podcast.title)")
        }
    }
}
