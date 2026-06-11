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

    func recentEpisodes(req: Request) async throws -> [EpisodeResponse] {
        let limit = min(max(req.query[Int.self, at: "limit"] ?? 100, 1), 500)
        return try await Episode.query(on: req.db)
            .with(\.$podcast)
            .sort(\.$publishedAt, .descending)
            .limit(limit)
            .all()
            .map { EpisodeResponse(episode: $0) }
    }

    func search(req: Request) async throws -> EpisodeSearchResponse {
        let q = (try? req.query.get(String.self, at: "q"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !q.isEmpty else { return EpisodeSearchResponse(podcasts: [], episodes: [], directory: []) }
        let rawScope = (try? req.query.get(String.self, at: "podcastID"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopePodcastID = (rawScope?.isEmpty == false) ? rawScope : nil

        let episodes = try await EpisodeSearchService().search(term: q, limit: 50, podcastStableID: scopePodcastID, on: req.db)

        // When scoped to a single show, only episodes are relevant — skip the
        // podcast catalog and directory lookups entirely.
        if scopePodcastID != nil {
            return EpisodeSearchResponse(podcasts: [], episodes: episodes, directory: [])
        }

        let podcasts = try await Podcast.query(on: req.db)
            .group(.or) { group in
                group.filter(\.$title ~~ q)
                group.filter(\.$feedURL ~~ q)
            }
            .limit(25)
            .all()
            .map(PodcastResponse.init)
        let directory = try await PodcastDirectorySearch().search(term: q, on: req.application)
        return EpisodeSearchResponse(podcasts: podcasts, episodes: episodes, directory: directory)
    }

    func episodesForPodcast(req: Request) async throws -> [EpisodeResponse] {
        let podcast = try await findPodcast(req)
        let limit = min(max(req.query[Int.self, at: "limit"] ?? 200, 1), 1000)
        let offset = max(req.query[Int.self, at: "offset"] ?? 0, 0)
        return try await Episode.query(on: req.db)
            .with(\.$podcast)
            .filter(\.$podcast.$id == podcast.requireID())
            .sort(\.$publishedAt, .descending)
            .offset(offset)
            .limit(limit)
            .all()
            .map { EpisodeResponse(episode: $0) }
    }

    func episode(req: Request) async throws -> EpisodeResponse {
        try await EpisodeResponse(episode: findEpisode(req))
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
    let podcasts: [PodcastResponse]
    let episodes: [EpisodeResponse]
    let directory: [PodcastDirectoryResult]
}
