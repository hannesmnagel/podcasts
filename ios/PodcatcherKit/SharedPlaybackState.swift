import Foundation

public struct SharedPlaybackState: Codable, Sendable, Equatable {
    public var episodeStableID: String?
    public var podcastStableID: String?
    public var title: String
    public var podcastTitle: String
    public var artworkFileURL: URL?
    public var isPlaying: Bool
    public var elapsed: TimeInterval
    public var duration: TimeInterval?
    public var speed: Double
    public var updatedAt: Date

    public init(
        episodeStableID: String? = nil,
        podcastStableID: String? = nil,
        title: String = "",
        podcastTitle: String = "",
        artworkFileURL: URL? = nil,
        isPlaying: Bool = false,
        elapsed: TimeInterval = 0,
        duration: TimeInterval? = nil,
        speed: Double = 1.0,
        updatedAt: Date = Date()
    ) {
        self.episodeStableID = episodeStableID
        self.podcastStableID = podcastStableID
        self.title = title
        self.podcastTitle = podcastTitle
        self.artworkFileURL = artworkFileURL
        self.isPlaying = isPlaying
        self.elapsed = elapsed
        self.duration = duration
        self.speed = speed
        self.updatedAt = updatedAt
    }
}
