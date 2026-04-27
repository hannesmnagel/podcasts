import Fluent
import Vapor

struct PodcastController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let podcasts = routes.grouped("podcasts")
        podcasts.post(use: create)
        podcasts.get(use: index)
        podcasts.post(":id", "crawl", use: crawl)
    }

    func create(req: Request) async throws -> PodcastResponse {
        let input = try req.content.decode(CreatePodcastRequest.self)
        let normalizedURL = StableID.normalizeURL(input.feedURL)
        let stableID = StableID.podcastID(feedURL: normalizedURL)
        if let existing = try await Podcast.query(on: req.db).filter(\.$stableID == stableID).first() {
            if input.crawlImmediately ?? true, existing.lastCrawledAt == nil {
                scheduleCrawl(for: existing, on: req.application)
            }
            return PodcastResponse(podcast: existing)
        }
        let podcast = Podcast(stableID: stableID, feedURL: normalizedURL, title: input.title ?? "")
        try await podcast.save(on: req.db)
        if input.crawlImmediately ?? true {
            scheduleCrawl(for: podcast, on: req.application)
        }
        return PodcastResponse(podcast: podcast)
    }

    func index(req: Request) async throws -> [PodcastResponse] {
        try await Podcast.query(on: req.db)
            .sort(\.$updatedAt, .descending)
            .all()
            .map(PodcastResponse.init)
    }

    func crawl(req: Request) async throws -> PodcastResponse {
        let podcast = try await findPodcast(req)
        try await FeedCrawler().crawl(podcast: podcast, on: req.application)
        return PodcastResponse(podcast: try await Podcast.find(try podcast.requireID(), on: req.db) ?? podcast)
    }

    private func scheduleCrawl(for podcast: Podcast, on app: Application) {
        guard let podcastID = podcast.id else { return }
        app.eventLoopGroup.next().execute {
            Task {
                do {
                    guard let podcast = try await Podcast.find(podcastID, on: app.db) else { return }
                    try await FeedCrawler().crawl(podcast: podcast, on: app)
                    app.logger.info("Crawled podcast \(podcastID)")
                } catch {
                    app.logger.report(error: error)
                }
            }
        }
    }

    private func findPodcast(_ req: Request) async throws -> Podcast {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        if let uuid = UUID(uuidString: id), let podcast = try await Podcast.find(uuid, on: req.db) { return podcast }
        if let podcast = try await Podcast.query(on: req.db).filter(\.$stableID == id).first() { return podcast }
        throw Abort(.notFound)
    }
}

struct CreatePodcastRequest: Content {
    let feedURL: String
    let title: String?
    let crawlImmediately: Bool?
}
