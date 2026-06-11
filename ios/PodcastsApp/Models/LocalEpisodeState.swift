import Foundation
import SwiftData

@Model
final class LocalEpisodeState {
    var episodeStableID: String = ""
    var podcastStableID: String = ""
    var title: String = ""
    var summary: String?
    var strippedSummary: String?
    var audioURL: URL = URL(string: "about:blank")!
    var imageURL: URL?
    var cachedImageFileURL: URL?
    var publishedAt: Date?
    var playbackPosition: TimeInterval = 0
    var duration: TimeInterval?
    var isDownloaded: Bool = false
    var isDeleted: Bool = false
    var downloadedFileURL: URL?
    var lastListenedAt: Date?
    var deletedAt: Date?
    var cachedAt: Date?
    var sortIndex: Int?

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
