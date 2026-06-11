import Foundation
import SwiftData

@Model
final class PodcastDailySummary {
    var id: UUID = UUID()
    var date: Date = Date()
    var podcastStableID: String = ""
    var podcastTitle: String = ""
    var listenedSeconds: Double = 0
    var playedSeconds: Double = 0

    init(date: Date, podcastStableID: String, podcastTitle: String) {
        self.id = UUID()
        self.date = date
        self.podcastStableID = podcastStableID
        self.podcastTitle = podcastTitle
        self.listenedSeconds = 0
        self.playedSeconds = 0
    }
}
