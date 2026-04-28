import Foundation
import SwiftData

@Model
final class LocalEpisodeState {
    @Attribute(.unique) var episodeStableID: String
    var podcastStableID: String
    var title: String
    var summary: String?
    var strippedSummary: String?
    var audioURL: URL
    var imageURL: URL?
    var cachedImageFileURL: URL?
    var publishedAt: Date?
    var playbackPosition: TimeInterval
    var duration: TimeInterval?
    var isDownloaded: Bool
    var isDeleted: Bool
    var downloadedFileURL: URL?
    var lastListenedAt: Date?
    var deletedAt: Date?
    var cachedAt: Date?

    init(episodeStableID: String, podcastStableID: String, title: String, audioURL: URL) {
        self.episodeStableID = episodeStableID
        self.podcastStableID = podcastStableID
        self.title = title
        self.summary = nil
        self.strippedSummary = nil
        self.audioURL = audioURL
        self.imageURL = nil
        self.cachedImageFileURL = nil
        self.publishedAt = nil
        self.playbackPosition = 0
        self.isDownloaded = false
        self.isDeleted = false
    }
}
