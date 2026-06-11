#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import AppIntents
import PodcatcherKit
import SwiftUI
import UIKit
import WidgetKit

// MARK: - Live Activity configuration (lives in the widget bundle target)

struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingActivityAttributes.self) { context in
            // Lock Screen / banner
            LockScreenLiveActivityView(context: context)
                .containerBackground(.fill.tertiary, for: .widget)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeadingView(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailingView(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottomView(context: context)
                }
            } compactLeading: {
                CompactArtworkView(url: context.attributes.artworkFileURL)
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.caption2)
                    .foregroundStyle(.primary)
            } minimal: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .font(.caption2)
            }
            .widgetURL(URL(string: "podcatcher://nowplaying"))
        }
    }
}

// MARK: - Lock Screen banner

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<NowPlayingActivityAttributes>

    var progress: Double {
        guard let d = context.state.duration, d > 0 else { return 0 }
        return min(1, context.state.elapsed / d)
    }

    var body: some View {
        HStack {
            LiveActivityArtworkView(url: context.attributes.artworkFileURL, size: 52)
            VStack(alignment: .leading) {
                Text(context.attributes.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(context.attributes.podcastTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if context.state.duration != nil {
                    ProgressView(value: progress)
                        .tint(.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button(intent: SkipBackIntent(seconds: 15)) {
                    Image(systemName: "gobackward.15")
                }
                .buttonStyle(.plain)
                Button(intent: PlayPauseIntent()) {
                    Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.plain)
                Button(intent: SkipForwardIntent(seconds: 30)) {
                    Image(systemName: "goforward.30")
                }
                .buttonStyle(.plain)
            }
            .font(.title2)
            .foregroundStyle(.primary)
        }
        .padding()
    }
}

// MARK: - Dynamic Island expanded regions

private struct ExpandedLeadingView: View {
    let context: ActivityViewContext<NowPlayingActivityAttributes>

    var body: some View {
        HStack {
            LiveActivityArtworkView(url: context.attributes.artworkFileURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(context.attributes.podcastTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 4)
    }
}

private struct ExpandedTrailingView: View {
    let context: ActivityViewContext<NowPlayingActivityAttributes>

    var body: some View {
        Button(intent: PlayPauseIntent()) {
            Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                .font(.title3)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 8)
    }
}

private struct ExpandedBottomView: View {
    let context: ActivityViewContext<NowPlayingActivityAttributes>

    var progress: Double {
        guard let d = context.state.duration, d > 0 else { return 0 }
        return min(1, context.state.elapsed / d)
    }

    var body: some View {
        HStack {
            Button(intent: SkipBackIntent(seconds: 15)) {
                Image(systemName: "gobackward.15")
            }
            .buttonStyle(.plain)
            if context.state.duration != nil {
                ProgressView(value: progress)
                    .tint(.white)
            } else {
                Spacer()
            }
            Button(intent: SkipForwardIntent(seconds: 30)) {
                Image(systemName: "goforward.30")
            }
            .buttonStyle(.plain)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

// MARK: - Compact artwork

private struct CompactArtworkView: View {
    let url: URL?

    var body: some View {
        Group {
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "headphones").font(.caption2)
            }
        }
        .frame(width: 20, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(.leading, 4)
    }
}

// MARK: - Artwork shared

private struct LiveActivityArtworkView: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "headphones")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
    }
}

#endif
