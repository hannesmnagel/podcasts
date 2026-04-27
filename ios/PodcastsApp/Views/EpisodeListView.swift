import SwiftUI

enum EpisodeListMode {
    case all
    case podcast(String)
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

    init(title: String, mode: EpisodeListMode) {
        self.title = title
        self.mode = mode
    }

    var body: some View {
        List(episodes) { episode in
            EpisodeRow(episode: episode)
        }
        .navigationTitle(title.isEmpty ? "Episodes" : title)
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
        default: "Add or crawl a podcast feed first."
        }
    }

    private func load() async {
        do {
            episodes = switch mode {
            case .all: try await client.allEpisodes()
            case .podcast(let podcastID): try await client.episodes(for: podcastID)
            case .search(let query): try await client.search(query).episodes
            case .placeholder: []
            }
        } catch { errorMessage = error.localizedDescription }
    }
}

struct EpisodeRow: View {
    let episode: EpisodeDTO

    var body: some View {
        NavigationLink {
            EpisodeDetailView(episode: episode)
        } label: {
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
    }
}
