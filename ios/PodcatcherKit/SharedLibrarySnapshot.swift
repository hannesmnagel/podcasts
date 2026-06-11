import Foundation

public struct SharedPodcastInfo: Codable, Sendable, Equatable {
    public var stableID: String
    public var title: String
    public var artworkFileURL: URL?

    public init(stableID: String, title: String, artworkFileURL: URL? = nil) {
        self.stableID = stableID
        self.title = title
        self.artworkFileURL = artworkFileURL
    }
}

public struct SharedEpisodeInfo: Codable, Sendable, Equatable {
    public var stableID: String
    public var podcastStableID: String?
    public var title: String
    public var podcastTitle: String
    public var duration: TimeInterval?
    public var publishedAt: Date?
    public var isPlayed: Bool
    public var playbackPosition: TimeInterval
    public var artworkFileURL: URL?

    public init(
        stableID: String,
        podcastStableID: String? = nil,
        title: String,
        podcastTitle: String,
        duration: TimeInterval? = nil,
        publishedAt: Date? = nil,
        isPlayed: Bool = false,
        playbackPosition: TimeInterval = 0,
        artworkFileURL: URL? = nil
    ) {
        self.stableID = stableID
        self.podcastStableID = podcastStableID
        self.title = title
        self.podcastTitle = podcastTitle
        self.duration = duration
        self.publishedAt = publishedAt
        self.isPlayed = isPlayed
        self.playbackPosition = playbackPosition
        self.artworkFileURL = artworkFileURL
    }
}

public struct SharedLibrarySnapshot: Codable, Sendable {
    public var subscriptions: [SharedPodcastInfo]
    public var recentEpisodes: [SharedEpisodeInfo]
    public var newestEpisode: SharedEpisodeInfo?
    public var updatedAt: Date

    public init(
        subscriptions: [SharedPodcastInfo] = [],
        recentEpisodes: [SharedEpisodeInfo] = [],
        newestEpisode: SharedEpisodeInfo? = nil,
        updatedAt: Date = Date()
    ) {
        self.subscriptions = subscriptions
        self.recentEpisodes = recentEpisodes
        self.newestEpisode = newestEpisode
        self.updatedAt = updatedAt
    }
}
