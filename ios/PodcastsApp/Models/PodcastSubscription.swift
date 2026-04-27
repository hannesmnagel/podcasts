import Foundation
import SwiftData

@Model
final class PodcastSubscription {
    @Attribute(.unique) var stableID: String
    var feedURL: URL
    var title: String
    var artworkURL: URL?
    var createdAt: Date
    var sortIndex: Int

    init(stableID: String, feedURL: URL, title: String = "", artworkURL: URL? = nil, sortIndex: Int = 0) {
        self.stableID = stableID
        self.feedURL = feedURL
        self.title = title
        self.artworkURL = artworkURL
        self.createdAt = .now
        self.sortIndex = sortIndex
    }
}
