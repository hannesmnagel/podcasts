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
    /// A highlighted excerpt (sentence around the match) for search results.
    /// Matched terms are wrapped in « » markers. Nil outside of search.
    let matchSnippet: String?
    /// Which field the search term was found in: "title", "summary", or "transcript".
    let matchField: String?

    init(episode: Episode, matchSnippet: String? = nil, matchField: String? = nil) {
        self.id = episode.id
        self.podcastStableID = episode.$podcast.value?.stableID ?? episode.$podcast.id.uuidString
        self.stableID = episode.stableID
        self.title = episode.title
        self.summary = episode.summary
        self.audioURL = episode.audioURL
        self.imageURL = episode.imageURL ?? episode.$podcast.value?.imageURL
        self.publishedAt = episode.publishedAt
        self.duration = episode.duration
        self.matchSnippet = matchSnippet
        self.matchField = matchField
    }

    init(
        id: UUID?,
        podcastStableID: String,
        stableID: String,
        title: String,
        summary: String?,
        audioURL: String,
        imageURL: String?,
        publishedAt: Date?,
        duration: TimeInterval?,
        matchSnippet: String?,
        matchField: String?
    ) {
        self.id = id
        self.podcastStableID = podcastStableID
        self.stableID = stableID
        self.title = title
        self.summary = summary
        self.audioURL = audioURL
        self.imageURL = imageURL
        self.publishedAt = publishedAt
        self.duration = duration
        self.matchSnippet = matchSnippet
        self.matchField = matchField
    }
}
