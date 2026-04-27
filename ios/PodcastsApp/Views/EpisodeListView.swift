import SwiftUI

enum EpisodeListMode {
    case podcast(String)
    case subscriptions([String])
    case search(String)
    case placeholder
}

struct EpisodeListView: View {
    let title: String
    let mode: EpisodeListMode

    @State private var episodes: [EpisodeDTO] = []
    @State private var errorMessage: String?
    private let client = BackendClient()

    init(title: String, podcastID: String? = nil) {
        self.title = title
        self.mode = podcastID.map(EpisodeListMode.podcast) ?? .placeholder
    }

    init(title: String, subscriptions: [PodcastSubscription]) {
        self.title = title
        self.mode = .subscriptions(subscriptions.map(\.stableID))
    }

    init(title: String, mode: EpisodeListMode) {
        self.title = title
        self.mode = mode
    }

    var body: some View {
        List(episodes) { episode in
            EpisodeRow(episode: episode)
        }
        .listStyle(.plain)
        .navigationTitle(title.isEmpty ? "Episodes" : title)
        .navigationDestination(for: EpisodeDTO.self) { episode in
            EpisodeDetailView(episode: episode)
        }
        .task { await load() }
        .refreshable { await load() }
        .overlay {
            if episodes.isEmpty {
                ContentUnavailableView("No Episodes", systemImage: "waveform", description: Text(emptyText))
            }
        }
        .alert("Backend error", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") { errorMessage = nil }
        }, message: { Text(errorMessage ?? "") })
    }

    private var emptyText: String {
        switch mode {
        case .placeholder: "This smart playlist is not wired yet."
        case .subscriptions(let ids) where ids.isEmpty: "Search for podcasts and add them to your library."
        default: "No crawled episodes yet."
        }
    }

    private func load() async {
        do {
            episodes = try await loadEpisodes()
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadEpisodes() async throws -> [EpisodeDTO] {
        switch mode {
        case .podcast(let podcastID): try await client.episodes(for: podcastID)
        case .subscriptions(let podcastIDs): try await loadSubscriptions(podcastIDs)
        case .search(let query): try await client.search(query).episodes
        case .placeholder: []
        }
    }

    private func loadSubscriptions(_ podcastIDs: [String]) async throws -> [EpisodeDTO] {
        try await withThrowingTaskGroup(of: [EpisodeDTO].self) { group in
            for podcastID in podcastIDs {
                group.addTask { try await client.episodes(for: podcastID) }
            }
            var episodes: [EpisodeDTO] = []
            for try await podcastEpisodes in group { episodes += podcastEpisodes }
            return episodes.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        }
    }
}

struct EpisodeRow: View {
    let episode: EpisodeDTO

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        NavigationLink(value: episode) {
            VStack(alignment: .leading, spacing: 6) {
                Text(episode.title)
                    .font(.headline)
                if let publishedAt = episode.publishedAt {
                    Text(publishedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let summary = episode.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button("Play", systemImage: "play.fill") {
                player.play(episode)
            }
            .tint(.orange)

            Button("Add", systemImage: "text.badge.plus") {}
                .disabled(true)
                .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(isPlayed ? "Unplayed" : "Played", systemImage: isPlayed ? "circle" : "checkmark.circle") {
                togglePlayed()
            }
            .tint(.green)

            Button("Delete", systemImage: "trash", role: .destructive) {}
                .disabled(true)
        }
        .contextMenu {
            Button("Play", systemImage: "play.fill") {
                player.play(episode)
            }
            Button("Add to Up Next", systemImage: "text.badge.plus") {}
                .disabled(true)
            Button(isPlayed ? "Mark as Unplayed" : "Mark as Played", systemImage: isPlayed ? "circle" : "checkmark.circle") {
                togglePlayed()
            }
            ShareLink(item: shareURL) {
                Label("Share Episode Link", systemImage: "square.and.arrow.up")
            }
            Button("Delete Episode", systemImage: "trash", role: .destructive) {}
                .disabled(true)
        }
    }

    private var isPlayed: Bool {
        LibraryStore.isPlayed(episode, in: modelContext)
    }

    private var shareURL: URL {
        URL(string: episode.audioURL) ?? URL(string: "https://podcasts.apple.com")!
    }

    private func togglePlayed() {
        if isPlayed {
            LibraryStore.markUnplayed(episode, in: modelContext)
        } else {
            LibraryStore.markPlayed(episode, in: modelContext)
        }
    }
}
