#if os(iOS) && !targetEnvironment(macCatalyst)
@preconcurrency import ActivityKit
import Foundation
import PodcatcherKit

@MainActor
final class LiveActivityController {
    private var activity: Activity<NowPlayingActivityAttributes>?
    private var currentEpisodeID: String?
    private var lastElapsedPush: Date = .distantPast
    private let elapsedThrottle: TimeInterval = 15

    func startOrUpdate(
        episode: EpisodeDTO,
        podcastTitle: String,
        artworkFileURL: URL?,
        isPlaying: Bool,
        elapsed: TimeInterval,
        duration: TimeInterval?,
        speed: Double
    ) {
        end()
    }

    private func _startOrUpdate(
        episode: EpisodeDTO,
        podcastTitle: String,
        artworkFileURL: URL?,
        isPlaying: Bool,
        elapsed: TimeInterval,
        duration: TimeInterval?,
        speed: Double
    ) {
        if activity != nil, currentEpisodeID == episode.stableID {
            updateState(isPlaying: isPlaying, elapsed: elapsed, duration: duration, speed: speed)
        } else {
            endImmediate()
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let attributes = NowPlayingActivityAttributes(
                episodeStableID: episode.stableID,
                title: episode.title,
                podcastTitle: podcastTitle,
                artworkFileURL: artworkFileURL
            )
            let state = NowPlayingActivityAttributes.ContentState(
                isPlaying: isPlaying, elapsed: elapsed, duration: duration, speed: speed
            )
            do {
                activity = try Activity.request(
                    attributes: attributes,
                    content: .init(state: state, staleDate: Date.now.addingTimeInterval(60))
                )
                currentEpisodeID = episode.stableID
                lastElapsedPush = Date()
            } catch {
                // Live Activity unavailable (simulator / user disabled)
            }
        }
    }

    func pushElapsedIfNeeded(isPlaying: Bool, elapsed: TimeInterval, duration: TimeInterval?, speed: Double) { }

    func end() {
        endImmediate()
    }

    private func updateState(isPlaying: Bool, elapsed: TimeInterval, duration: TimeInterval?, speed: Double) {
        guard let activity else { return }
        let state = NowPlayingActivityAttributes.ContentState(
            isPlaying: isPlaying, elapsed: elapsed, duration: duration, speed: speed
        )
        let content = ActivityContent(state: state, staleDate: Date.now.addingTimeInterval(60))
        Task { @MainActor in
            await activity.update(content)
        }
        lastElapsedPush = Date()
    }

    private func endImmediate() {
        guard let a = activity else { return }
        activity = nil
        currentEpisodeID = nil
        Task { @MainActor in
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }
}

#else

import Foundation
import PodcatcherKit

// Stub for Mac Catalyst — Live Activities are iPhone-only
@MainActor
final class LiveActivityController {
    func startOrUpdate(episode: EpisodeDTO, podcastTitle: String, artworkFileURL: URL?,
                       isPlaying: Bool, elapsed: TimeInterval, duration: TimeInterval?, speed: Double) {}
    func pushElapsedIfNeeded(isPlaying: Bool, elapsed: TimeInterval, duration: TimeInterval?, speed: Double) {}
    func end() {}
}

#endif
