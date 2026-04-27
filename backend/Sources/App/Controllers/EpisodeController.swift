import Fluent
import Vapor

struct EpisodeController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let episodes = routes.grouped("episodes")
        episodes.get(use: recentEpisodes)
        episodes.get("search", use: search)
        episodes.get(":id", use: episode)
        routes.grouped("podcasts", ":podcastID", "episodes").get(use: episodesForPodcast)
    }

    func recentEpisodes(req: Request) async throws -> [Episode] {
        let limit = min(max(req.query[Int.self, at: "limit"] ?? 100, 1), 500)
        return try await Episode.query(on: req.db)
            .sort(\.$publishedAt, .descending)
            .limit(limit)
            .all()
    }

    func search(req: Request) async throws -> EpisodeSearchResponse {
        let q = (try? req.query.get(String.self, at: "q"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !q.isEmpty else { return EpisodeSearchResponse(podcasts: [], episodes: [], directory: []) }
        let podcasts = try await Podcast.query(on: req.db)
            .group(.or) { group in
                group.filter(\.$title ~~ q)
                group.filter(\.$feedURL ~~ q)
            }
            .limit(25)
            .all()
        let episodes = try await Episode.query(on: req.db)
            .group(.or) { group in
                group.filter(\.$title ~~ q)
                group.filter(\.$summary ~~ q)
            }
            .sort(\.$publishedAt, .descending)
            .limit(50)
            .all()
        let directory = try await PodcastDirectorySearch().search(term: q, on: req.application)
        return EpisodeSearchResponse(podcasts: podcasts, episodes: episodes, directory: directory)
    }

    func episodesForPodcast(req: Request) async throws -> [Episode] {
        let podcast = try await findPodcast(req)
        return try await Episode.query(on: req.db)
            .filter(\.$podcast.$id == podcast.requireID())
            .sort(\.$publishedAt, .descending)
            .all()
    }

    func episode(req: Request) async throws -> Episode {
        try await findEpisode(req)
    }

    private func findPodcast(_ req: Request) async throws -> Podcast {
        guard let id = req.parameters.get("podcastID") else { throw Abort(.badRequest) }
        if let uuid = UUID(uuidString: id), let podcast = try await Podcast.find(uuid, on: req.db) { return podcast }
        if let podcast = try await Podcast.query(on: req.db).filter(\.$stableID == id).first() { return podcast }
        throw Abort(.notFound)
    }

    private func findEpisode(_ req: Request) async throws -> Episode {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        if let uuid = UUID(uuidString: id), let episode = try await Episode.find(uuid, on: req.db) { return episode }
        if let episode = try await Episode.query(on: req.db).filter(\.$stableID == id).first() { return episode }
        throw Abort(.notFound)
    }
}

struct EpisodeSearchResponse: Content {
    let podcasts: [Podcast]
    let episodes: [Episode]
    let directory: [PodcastDirectoryResult]
}
