import Foundation
import SwiftData

@Model
final class AppEvent {
    var id: UUID = UUID()
    var occurredAt: Date = Date()
    var kind: String = ""
    var episodeStableID: String?
    var episodeTitle: String?
    var podcastStableID: String?
    var podcastTitle: String?
    // Playback-specific
    var startPosition: Double?
    var endPosition: Double?
    var playbackSpeed: Double?

    init(
        kind: String,
        episodeStableID: String? = nil,
        episodeTitle: String? = nil,
        podcastStableID: String? = nil,
        podcastTitle: String? = nil,
        startPosition: Double? = nil,
        endPosition: Double? = nil,
        playbackSpeed: Double? = nil
    ) {
        self.id = UUID()
        self.occurredAt = .now
        self.kind = kind
        self.episodeStableID = episodeStableID
        self.episodeTitle = episodeTitle
        self.podcastStableID = podcastStableID
        self.podcastTitle = podcastTitle
        self.startPosition = startPosition
        self.endPosition = endPosition
        self.playbackSpeed = playbackSpeed
    }

    enum Kind {
        static let playback = "playback"
        static let markPlayed = "markPlayed"
        static let markUnplayed = "markUnplayed"
        static let hide = "hide"
        static let restore = "restore"
        static let download = "download"
        static let deleteDownload = "deleteDownload"
        static let historySeek = "historySeek"
    }
}
