import Foundation
import SwiftData

@Model
final class LocalEpisodeState {
    @Attribute(.unique) var episodeStableID: String
    var podcastStableID: String
    var title: String
    var audioURL: URL
    var playbackPosition: TimeInterval
    var duration: TimeInterval?
    var isDownloaded: Bool
    var downloadedFileURL: URL?
    var lastListenedAt: Date?

    init(episodeStableID: String, podcastStableID: String, title: String, audioURL: URL) {
        self.episodeStableID = episodeStableID
        self.podcastStableID = podcastStableID
        self.title = title
        self.audioURL = audioURL
        self.playbackPosition = 0
        self.isDownloaded = false
    }
}
