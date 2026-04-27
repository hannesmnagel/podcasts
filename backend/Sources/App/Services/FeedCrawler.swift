import FeedKit
import Fluent
import Vapor

struct FeedCrawler: Sendable {
    func crawl(podcast: Podcast, on app: Application) async throws {
        let response = try await app.client.get(URI(string: podcast.feedURL), headers: requestHeaders(for: podcast))
        if response.status == .notModified { return }
        guard response.status == .ok else { throw Abort(response.status) }
        guard let body = response.body else { throw Abort(.badGateway, reason: "Feed body was empty") }

        if let etag = response.headers.first(name: .eTag) { podcast.etag = etag }
        if let lastModified = response.headers.first(name: .lastModified) { podcast.lastModified = lastModified }

        let data = Data(buffer: body)
        let result = FeedParser(data: data).parse()
        guard case .success(let parsed) = result else { throw Abort(.unprocessableEntity, reason: "Feed could not be parsed") }

        switch parsed {
        case .rss(let rss):
            podcast.title = rss.title ?? podcast.title
            podcast.description = rss.description
            podcast.imageURL = rss.image?.url ?? rss.iTunes?.iTunesImage?.attributes?.href
            podcast.lastCrawledAt = Date()
            try await podcast.save(on: app.db)
            try await upsertRSSItems(rss.items ?? [], podcast: podcast, on: app)
        case .atom(let atom):
            podcast.title = atom.title ?? podcast.title
            podcast.description = atom.subtitle?.value
            podcast.lastCrawledAt = Date()
            try await podcast.save(on: app.db)
            try await upsertAtomEntries(atom.entries ?? [], podcast: podcast, on: app)
        case .json:
            podcast.lastCrawledAt = Date()
            try await podcast.save(on: app.db)
        }
    }

    private func requestHeaders(for podcast: Podcast) -> HTTPHeaders {
        var headers = HTTPHeaders()
        if let etag = podcast.etag { headers.add(name: .ifNoneMatch, value: etag) }
        if let lastModified = podcast.lastModified { headers.add(name: .ifModifiedSince, value: lastModified) }
        headers.add(name: .userAgent, value: "PrivacySpeedPodcastsBot/0.1 (+https://hannesnagel.com)")
        return headers
    }

    private func upsertRSSItems(_ items: [RSSFeedItem], podcast: Podcast, on app: Application) async throws {
        let podcastUUID = try podcast.requireID()
        for item in items {
            guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let audioURL = item.enclosure?.attributes?.url else { continue }
            let guid = item.guid?.value
            let stableID = StableID.episodeID(podcastID: podcast.stableID, guid: guid, audioURL: audioURL, title: title, publishedAt: item.pubDate)
            let episode = try await Episode.query(on: app.db).filter(\.$stableID == stableID).first() ?? Episode(podcastID: podcastUUID, stableID: stableID, guid: guid, title: title, audioURL: audioURL)
            episode.title = title
            episode.summary = item.description ?? item.iTunes?.iTunesSubtitle
            episode.audioURL = audioURL
            episode.imageURL = item.iTunes?.iTunesImage?.attributes?.href
            episode.publishedAt = item.pubDate
            episode.duration = item.iTunes?.iTunesDuration
            try await episode.save(on: app.db)
        }
    }

    private func upsertAtomEntries(_ entries: [AtomFeedEntry], podcast: Podcast, on app: Application) async throws {
        let podcastUUID = try podcast.requireID()
        for entry in entries {
            guard let title = entry.title, !title.isEmpty else { continue }
            let audioURL = entry.links?.first(where: { $0.attributes?.type?.hasPrefix("audio/") == true })?.attributes?.href
            guard let audioURL else { continue }
            let stableID = StableID.episodeID(podcastID: podcast.stableID, guid: entry.id, audioURL: audioURL, title: title, publishedAt: entry.published)
            let episode = try await Episode.query(on: app.db).filter(\.$stableID == stableID).first() ?? Episode(podcastID: podcastUUID, stableID: stableID, guid: entry.id, title: title, audioURL: audioURL)
            episode.title = title
            episode.summary = entry.summary?.value
            episode.audioURL = audioURL
            episode.publishedAt = entry.published
            try await episode.save(on: app.db)
        }
    }
}
