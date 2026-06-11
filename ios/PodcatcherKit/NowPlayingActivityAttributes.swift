#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

public struct NowPlayingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var isPlaying: Bool
        public var elapsed: TimeInterval
        public var duration: TimeInterval?
        public var speed: Double
        public var updatedAt: Date

        public init(isPlaying: Bool, elapsed: TimeInterval, duration: TimeInterval?, speed: Double, updatedAt: Date = Date()) {
            self.isPlaying = isPlaying
            self.elapsed = elapsed
            self.duration = duration
            self.speed = speed
            self.updatedAt = updatedAt
        }
    }

    public var episodeStableID: String
    public var title: String
    public var podcastTitle: String
    public var artworkFileURL: URL?

    public init(episodeStableID: String, title: String, podcastTitle: String, artworkFileURL: URL? = nil) {
        self.episodeStableID = episodeStableID
        self.title = title
        self.podcastTitle = podcastTitle
        self.artworkFileURL = artworkFileURL
    }
}
#endif
