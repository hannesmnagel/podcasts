import PodcatcherKit
import SwiftUI
import UIKit
import WidgetKit


// MARK: - Entry

struct ContinueListeningEntry: TimelineEntry {
    let date: Date
    let episodes: [SharedEpisodeInfo]

    static let placeholder = ContinueListeningEntry(date: .now, episodes: [
        SharedEpisodeInfo(stableID: "1", title: "Episode One", podcastTitle: "Podcast A", duration: 3600, playbackPosition: 900),
        SharedEpisodeInfo(stableID: "2", title: "Episode Two", podcastTitle: "Podcast B", duration: 2700, playbackPosition: 300)
    ])
}

// MARK: - Provider

struct ContinueListeningProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueListeningEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (ContinueListeningEntry) -> Void) {
        completion(entry(from: SharedStateReader.librarySnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueListeningEntry>) -> Void) {
        let current = entry(from: SharedStateReader.librarySnapshot())
        let nextRefresh = Date.now.addingTimeInterval(15 * 60)
        completion(Timeline(entries: [current], policy: .after(nextRefresh)))
    }

    private func entry(from snapshot: SharedLibrarySnapshot?) -> ContinueListeningEntry {
        ContinueListeningEntry(date: .now, episodes: snapshot?.recentEpisodes ?? [])
    }
}

// MARK: - Widget

struct ContinueListeningWidget: Widget {
    let kind = "com.nagel.podcasts.continuelistening"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ContinueListeningProvider()) { entry in
            ContinueListeningWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Continue Listening")
        .description("Your recently listened-to episodes.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Root view

struct ContinueListeningWidgetView: View {
    let entry: ContinueListeningEntry
    @Environment(\.widgetFamily) private var family

    private var rowCount: Int { family == .systemLarge ? 5 : 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Up Next")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if entry.episodes.isEmpty {
                Spacer()
                Text("No unplayed episodes yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                Spacer()
            } else {
                ForEach(entry.episodes.prefix(rowCount), id: \.stableID) { episode in
                    Link(destination: URL(string: "podcatcher://episode/\(episode.stableID)")!) {
                        EpisodeRow(episode: episode)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Episode row

struct EpisodeRow: View {
    let episode: SharedEpisodeInfo

    var progress: Double {
        guard let d = episode.duration, d > 0 else { return 0 }
        return min(1, episode.playbackPosition / d)
    }

    var body: some View {
        HStack {
            SmallArtworkView(url: episode.artworkFileURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(episode.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(episode.podcastTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if episode.duration != nil {
                    ProgressView(value: progress)
                        .tint(.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct SmallArtworkView: View {
    let url: URL?
    private let size: CGFloat = 36
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let url, let uiImage = loadThumbnail(url: url, pointSize: size, scale: displayScale) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "headphones")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
