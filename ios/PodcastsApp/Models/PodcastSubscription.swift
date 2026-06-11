import Foundation
import SwiftData

@Model
final class PodcastSubscription {
    var stableID: String = ""
    var feedURL: URL = URL(string: "about:blank")!
    var title: String = ""
    var podcastDescription: String?
    var artworkURL: URL?
    var createdAt: Date = Date()
    var sortIndex: Int = 0
    var downloadPolicyRawValue: String?
    var playbackSpeed: Double?

    init(stableID: String, feedURL: URL, title: String = "", artworkURL: URL? = nil, sortIndex: Int = 0) {
        self.stableID = stableID
        self.feedURL = feedURL
        self.title = title
        self.podcastDescription = nil
        self.artworkURL = artworkURL
        self.createdAt = .now
        self.sortIndex = sortIndex
        self.downloadPolicyRawValue = nil
        self.playbackSpeed = nil
    }
}
