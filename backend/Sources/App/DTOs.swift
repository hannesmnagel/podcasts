import Foundation
import Vapor

struct PodcastResponse: Content {
    let id: UUID?
    let stableID: String
    let feedURL: String
    let title: String
    let description: String?
    let imageURL: String?
    let lastCrawledAt: Date?

    init(podcast: Podcast) {
        self.id = podcast.id
        self.stableID = podcast.stableID
        self.feedURL = podcast.feedURL
        self.title = podcast.title
        self.description = podcast.description
        self.imageURL = podcast.imageURL
        self.lastCrawledAt = podcast.lastCrawledAt
    }
}

struct EpisodeResponse: Content {
    let id: UUID?
    let podcastStableID: String
    let stableID: String
    let title: String
    let summary: String?
    let audioURL: String
    let imageURL: String?
    let publishedAt: Date?
    let duration: TimeInterval?

    init(episode: Episode) {
        self.id = episode.id
        self.podcastStableID = episode.$podcast.value?.stableID ?? episode.$podcast.id.uuidString
        self.stableID = episode.stableID
        self.title = episode.title
        self.summary = episode.summary
        self.audioURL = episode.audioURL
        self.imageURL = episode.imageURL
        self.publishedAt = episode.publishedAt
        self.duration = episode.duration
    }
}
