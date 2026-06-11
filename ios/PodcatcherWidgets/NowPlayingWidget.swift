import AppIntents
import PodcatcherKit
import SwiftUI
import UIKit
import WidgetKit

// MARK: - Entry

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let episodeStableID: String?
    let title: String
    let podcastTitle: String
    let artworkFileURL: URL?
    let isPlaying: Bool
    let elapsed: TimeInterval
    let duration: TimeInterval?

    var progress: Double {
        guard let d = duration, d > 0 else { return 0 }
        return min(1, elapsed / d)
    }

    var remainingText: String {
        guard let d = duration, d > 0 else { return "" }
        let r = max(0, d - elapsed)
        let mins = Int(r / 60)
        return mins > 0 ? "-\(mins)m" : "<1m"
    }

    static let placeholder = NowPlayingEntry(
        date: .now,
        episodeStableID: nil,
        title: "Episode Title",
        podcastTitle: "Podcast Name",
        artworkFileURL: nil,
        isPlaying: false,
        elapsed: 1200,
        duration: 3600
    )

    static let empty = NowPlayingEntry(
        date: .now,
        episodeStableID: nil,
        title: "",
        podcastTitle: "",
        artworkFileURL: nil,
        isPlaying: false,
        elapsed: 0,
        duration: nil
    )
}

// MARK: - Provider

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(entry(from: SharedStateReader.currentPlaybackState()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let current = entry(from: SharedStateReader.currentPlaybackState())
        let nextRefresh = Date.now.addingTimeInterval(15 * 60)
        completion(Timeline(entries: [current], policy: .after(nextRefresh)))
    }

    private func entry(from state: SharedPlaybackState?) -> NowPlayingEntry {
        if let state, state.episodeStableID != nil {
            return NowPlayingEntry(
                date: .now,
                episodeStableID: state.episodeStableID,
                title: state.title,
                podcastTitle: state.podcastTitle,
                artworkFileURL: state.artworkFileURL,
                isPlaying: state.isPlaying,
                elapsed: state.elapsed,
                duration: state.duration
            )
        }
        if let newest = SharedStateReader.librarySnapshot()?.newestEpisode {
            return NowPlayingEntry(
                date: .now,
                episodeStableID: newest.stableID,
                title: newest.title,
                podcastTitle: newest.podcastTitle,
                artworkFileURL: newest.artworkFileURL,
                isPlaying: false,
                elapsed: newest.playbackPosition,
                duration: newest.duration
            )
        }
        return .empty
    }
}

// MARK: - Widget

struct NowPlayingWidget: Widget {
    let kind = "com.nagel.podcasts.nowplaying"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Now Playing")
        .description("Shows the currently playing episode.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryCircular, .accessoryInline, .accessoryRectangular
        ])
        .contentMarginsDisabled()
        .backgroundTask(.appRefresh("com.nagel.podcasts.nowplaying")) { }
    }
}

// MARK: - Root view

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .systemSmall:    NowPlayingSmallView(entry: entry)
            case .systemMedium:   NowPlayingMediumView(entry: entry)
            case .accessoryCircular:   NowPlayingCircularView(entry: entry)
            case .accessoryInline:     NowPlayingInlineView(entry: entry)
            case .accessoryRectangular: NowPlayingRectangularView(entry: entry)
            default:              NowPlayingSmallView(entry: entry)
            }
        }
        .widgetURL(URL(string: "podcatcher://nowplaying"))
    }
}

// MARK: - systemSmall

struct NowPlayingSmallView: View {
    let entry: NowPlayingEntry

    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                ArtworkView(url: entry.artworkFileURL, size: 64)
                Spacer(minLength: 0)
                if entry.episodeStableID != nil {
                    Button(intent: PlayPauseIntent()) {
                        Image(systemName: entry.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .padding(10)
                            .background(Circle().fill(.fill.tertiary))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
            if entry.episodeStableID == nil {
                Text("Nothing\nPlaying")
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            } else {
                Text(entry.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Text(entry.podcastTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if entry.duration != nil {
                    ProgressView(value: entry.progress)
                        .tint(.primary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - systemMedium

struct NowPlayingMediumView: View {
    let entry: NowPlayingEntry

    var body: some View {
        Group {
            if entry.episodeStableID == nil {
                Text("Nothing Playing")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    ArtworkView(url: entry.artworkFileURL, size: 104)
                    VStack(alignment: .leading) {
                        Text(entry.title)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(2)
                        Text(entry.podcastTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if entry.duration != nil {
                            ProgressView(value: entry.progress)
                                .tint(.primary)
                        }
                        HStack {
                            Text(entry.remainingText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button(intent: PlayPauseIntent()) {
                                Image(systemName: entry.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title3)
                                    .padding(10)
                                    .background(Circle().fill(.fill.tertiary))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - accessoryCircular

struct NowPlayingCircularView: View {
    let entry: NowPlayingEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if entry.episodeStableID == nil {
                Image(systemName: "headphones")
                    .font(.title3)
                    .widgetAccentable()
            } else {
                Gauge(value: entry.progress) {
                    EmptyView()
                } currentValueLabel: {
                    Image(systemName: entry.isPlaying ? "pause.fill" : "play.fill")
                        .widgetAccentable()
                }
                .gaugeStyle(.accessoryCircularCapacity)
            }
        }
    }
}

// MARK: - accessoryInline

struct NowPlayingInlineView: View {
    let entry: NowPlayingEntry

    var body: some View {
        if entry.episodeStableID == nil {
            Label("The Podcatcher", systemImage: "headphones")
        } else {
            Label(entry.title, systemImage: entry.isPlaying ? "pause.fill" : "play.fill")
        }
    }
}

// MARK: - accessoryRectangular

struct NowPlayingRectangularView: View {
    let entry: NowPlayingEntry

    var body: some View {
        if entry.episodeStableID == nil {
            VStack(alignment: .leading) {
                Label("The Podcatcher", systemImage: "headphones")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("Tap to start listening")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading) {
                Text(entry.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .widgetAccentable()
                Text(entry.podcastTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if entry.duration != nil {
                    ProgressView(value: entry.progress)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Artwork helper

struct ArtworkView: View {
    let url: URL?
    let size: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let url, let uiImage = loadThumbnail(url: url, pointSize: size, scale: displayScale) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Image(systemName: "headphones")
                    .font(.system(size: size * 0.35))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(.quaternary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }
}

