import FeedKit
import Fluent
import Vapor

struct FeedCrawler: Sendable {
    func crawl(podcast: Podcast, on app: Application) async throws {
        let podcastID = try podcast.requireID()
        let freshPodcast = try await Podcast.find(podcastID, on: app.db) ?? podcast
        let response = try await app.client.get(URI(string: freshPodcast.feedURL), headers: requestHeaders(for: freshPodcast))
        if response.status == .notModified { return }
        guard response.status == .ok else { throw Abort(response.status) }
        guard let body = response.body else { throw Abort(.badGateway, reason: "Feed body was empty") }

        if let etag = response.headers.first(name: .eTag) { freshPodcast.etag = etag }
        if let lastModified = response.headers.first(name: .lastModified) { freshPodcast.lastModified = lastModified }

        let data = Data(buffer: body)
        let feedChapterSets = FeedChapterExtractor().rssChapters(from: data, relativeTo: freshPodcast.feedURL)
        let result = FeedParser(data: data).parse()
        guard case .success(let parsed) = result else { throw Abort(.unprocessableEntity, reason: "Feed could not be parsed") }

        switch parsed {
        case .rss(let rss):
            freshPodcast.title = rss.title ?? freshPodcast.title
            freshPodcast.description = firstNonEmpty(
                rss.iTunes?.iTunesSummary,
                rss.description,
                rss.iTunes?.iTunesSubtitle,
                freshPodcast.description
            )
            freshPodcast.imageURL = firstNonEmptyURL(
                rss.iTunes?.iTunesImage?.attributes?.href,
                rss.image?.url,
                freshPodcast.imageURL,
                relativeTo: freshPodcast.feedURL
            )
            freshPodcast.lastCrawledAt = Date()
            try await freshPodcast.save(on: app.db)
            try await upsertRSSItems(rss.items ?? [], podcast: freshPodcast, chapterSets: feedChapterSets, on: app)
        case .atom(let atom):
            freshPodcast.title = atom.title ?? freshPodcast.title
            freshPodcast.description = firstNonEmpty(atom.subtitle?.value, freshPodcast.description)
            freshPodcast.imageURL = firstNonEmptyURL(atom.logo, atom.icon, freshPodcast.imageURL, relativeTo: freshPodcast.feedURL)
            freshPodcast.lastCrawledAt = Date()
            try await freshPodcast.save(on: app.db)
            try await upsertAtomEntries(atom.entries ?? [], podcast: freshPodcast, on: app)
        case .json:
            freshPodcast.lastCrawledAt = Date()
            try await freshPodcast.save(on: app.db)
        }
    }

    private func requestHeaders(for podcast: Podcast) -> HTTPHeaders {
        var headers = HTTPHeaders()
        if let etag = podcast.etag { headers.add(name: .ifNoneMatch, value: etag) }
        if let lastModified = podcast.lastModified { headers.add(name: .ifModifiedSince, value: lastModified) }
        headers.add(name: .userAgent, value: "PrivacySpeedPodcastsBot/0.1 (+https://hannesnagel.com)")
        return headers
    }

    private func upsertRSSItems(_ items: [RSSFeedItem], podcast: Podcast, chapterSets: [String: FeedChapterSet], on app: Application) async throws {
        let podcastUUID = try podcast.requireID()
        for item in items {
            guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let audioURL = item.enclosure?.attributes?.url else { continue }
            let guid = item.guid?.value
            let stableID = StableID.episodeID(podcastID: podcast.stableID, guid: guid, audioURL: audioURL, title: title, publishedAt: item.pubDate)
            let episode = try await Episode.query(on: app.db).filter(\.$stableID == stableID).first() ?? Episode(podcastID: podcastUUID, stableID: stableID, guid: guid, title: title, audioURL: audioURL)
            episode.title = title
            episode.summary = firstNonEmpty(
                item.content?.contentEncoded,
                item.iTunes?.iTunesSummary,
                item.description,
                item.iTunes?.iTunesSubtitle
            )
            episode.audioURL = audioURL
            episode.imageURL = firstNonEmptyURL(
                item.iTunes?.iTunesImage?.attributes?.href,
                item.media?.mediaThumbnails?.first?.attributes?.url,
                item.media?.mediaContents?.lazy.compactMap { $0.mediaThumbnails?.first?.attributes?.url }.first,
                podcast.imageURL,
                relativeTo: podcast.feedURL
            )
            episode.publishedAt = item.pubDate
            episode.duration = item.iTunes?.iTunesDuration
            try await episode.save(on: app.db)
            if let chapterSet = chapterSets[chapterKey(guid: guid, audioURL: audioURL)] ?? chapterSets["audio:\(audioURL)"] {
                try await saveChapters(chapterSet, for: episode, on: app)
            }
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

    private func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func firstNonEmptyURL(_ values: String?..., relativeTo feedURL: String) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            .flatMap { absoluteURLString($0, relativeTo: feedURL) }
    }

    private func absoluteURLString(_ value: String, relativeTo feedURL: String) -> String? {
        guard let feedURL = URL(string: feedURL) else { return value }
        return URL(string: value, relativeTo: feedURL)?.absoluteURL.absoluteString ?? value
    }

    private func chapterKey(guid: String?, audioURL: String) -> String {
        if let guid = guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty {
            return "guid:\(guid)"
        }
        return "audio:\(audioURL)"
    }

    private func saveChapters(_ chapterSet: FeedChapterSet, for episode: Episode, on app: Application) async throws {
        let chapters: [FeedEpisodeChapter]
        if chapterSet.chapters.count > 1 {
            chapters = chapterSet.chapters
        } else if let remoteURL = chapterSet.remoteURL {
            guard let response = try? await app.client.get(URI(string: remoteURL)) else { return }
            guard response.status == .ok, let body = response.body else { return }
            chapters = FeedChapterExtractor().podcastChapters(from: Data(buffer: body), relativeTo: remoteURL)
        } else {
            return
        }
        guard chapters.count > 1 else { return }

        let episodeID = try episode.requireID()
        let existing = try await ChapterArtifact.query(on: app.db)
            .filter(\.$episode.$id == episodeID)
            .filter(\.$source == chapterSet.source)
            .first()
        let artifact = existing ?? ChapterArtifact()
        artifact.$episode.id = episodeID
        artifact.source = chapterSet.source
        artifact.chaptersJSON = String(decoding: try JSONEncoder().encode(chapters), as: UTF8.self)
        try await artifact.save(on: app.db)
    }
}
