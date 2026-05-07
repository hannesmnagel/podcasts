import Fluent
import Vapor

struct ArtifactController: RouteCollection {
    private let chaptersEnabled = false

    func boot(routes: any RoutesBuilder) throws {
        let episodes = routes.grouped("episodes", ":id")
        episodes.post("artifact-requests", use: requestArtifacts)
        episodes.get("transcript", use: transcript)
        episodes.get("fingerprint", use: fingerprint)
        episodes.get("chapters", use: chapters)
        episodes.post("transcript", use: uploadTranscript)
        episodes.post("fingerprint", use: uploadFingerprint)
        episodes.post("chapters", use: uploadChapters)
    }

    func requestArtifacts(req: Request) async throws -> ArtifactRequestResponse {
        let episode = try await findEpisode(req)
        let episodeID = try episode.requireID()
        let input = try req.content.decode(ArtifactDemandRequest.self)
        let demand = try await ArtifactRequest.query(on: req.db).filter(\.$episode.$id == episodeID).first() ?? ArtifactRequest(episodeID: episodeID)
        if input.transcript ?? true { demand.transcriptCount += 1 }
        // Chapterization is intentionally disabled for now. Keep accepting the
        // request field for API compatibility, but do not increment demand or
        // schedule chapter jobs until we have a cheaper/reliable chapterizer.
        if chaptersEnabled, input.chapters ?? true { demand.chapterCount += 1 }
        if input.fingerprint ?? false { demand.fingerprintCount += 1 }
        try await demand.save(on: req.db)

        let podcastDemand = try await incrementPodcastDemand(for: episode, input: input, on: req.db)
        let podcastPriorityBoost = podcastDemand.priorityScore
        // Fingerprints are currently produced as part of transcript jobs so both
        // artifacts refer to the same worker-fetched rendition. If an old
        // transcript exists without a fingerprint, queue a fresh transcript job.
        let wantsTranscript = input.transcript ?? true
        let wantsFingerprint = input.fingerprint ?? false
        let hasTranscriptReadyForAlignment = try await transcriptReadyForAlignment(episodeID: episodeID, on: req.db)
        let hasFingerprint = try await artifactExists(episodeID: episodeID, kind: "fingerprint", on: req.db)
        let needsTranscript = wantsTranscript && !hasTranscriptReadyForAlignment
        let needsFingerprint = wantsFingerprint && !hasFingerprint
        if needsTranscript || needsFingerprint {
            try await ensureWorkerJob(episodeID: episodeID, kind: "transcript", priority: demand.transcriptCount * 3 + demand.fingerprintCount + podcastPriorityBoost, on: req.db)
        }
        if chaptersEnabled, input.chapters ?? true, !(try await artifactExists(episodeID: episodeID, kind: "chapters", on: req.db)) {
            try await ensureWorkerJob(episodeID: episodeID, kind: "chapters", priority: demand.chapterCount * 2 + podcastPriorityBoost, on: req.db)
        }
        return ArtifactRequestResponse(episodeID: episode.stableID, transcriptCount: demand.transcriptCount, chapterCount: demand.chapterCount, fingerprintCount: demand.fingerprintCount)
    }

    private func incrementPodcastDemand(for episode: Episode, input: ArtifactDemandRequest, on db: any Database) async throws -> PodcastDemand {
        let podcastID = episode.$podcast.id
        let demand = try await PodcastDemand.query(on: db).filter(\.$podcast.$id == podcastID).first() ?? PodcastDemand(podcastID: podcastID)
        if input.transcript ?? true { demand.transcriptRequests += 1 }
        // See requestArtifacts: chapter jobs are disabled until chapterization is reliable.
        if chaptersEnabled, input.chapters ?? true { demand.chapterRequests += 1 }
        if input.fingerprint ?? false { demand.fingerprintRequests += 1 }
        try await demand.save(on: db)
        try await boostPendingJobs(for: podcastID, by: demand.priorityScore, on: db)
        return demand
    }

    private func boostPendingJobs(for podcastID: UUID, by score: Int, on db: any Database) async throws {
        let episodes = try await Episode.query(on: db).filter(\.$podcast.$id == podcastID).all()
        let episodeIDs = try episodes.map { try $0.requireID() }
        for episodeID in episodeIDs {
            let jobs = try await WorkerJob.query(on: db)
                .filter(\.$episode.$id == episodeID)
                .filter(\.$status == "pending")
                .all()
            for job in jobs {
                job.priority = max(job.priority, score)
                try await job.save(on: db)
            }
        }
    }

    func transcript(req: Request) async throws -> TranscriptArtifact {
        let episode = try await findEpisode(req)
        guard let artifact = try await TranscriptArtifact.query(on: req.db)
            .filter(\.$episode.$id == episode.requireID())
            .sort(\.$createdAt, .descending)
            .first() else {
            throw Abort(.notFound)
        }
        return artifact
    }

    func fingerprint(req: Request) async throws -> FingerprintArtifact {
        let episode = try await findEpisode(req)
        guard let artifact = try await FingerprintArtifact.query(on: req.db)
            .filter(\.$episode.$id == episode.requireID())
            .sort(\.$createdAt, .descending)
            .first() else {
            throw Abort(.notFound)
        }
        return artifact
    }

    func chapters(req: Request) async throws -> ChapterArtifact {
        let episode = try await findEpisode(req)
        guard let artifact = try await ChapterArtifact.query(on: req.db)
            .filter(\.$episode.$id == episode.requireID())
            .sort(\.$createdAt, .descending)
            .first() else {
            throw Abort(.notFound)
        }
        return artifact
    }

    func uploadTranscript(req: Request) async throws -> TranscriptArtifact {
        let episode = try await findEpisode(req)
        let input = try req.content.decode(TranscriptUpload.self)
        let artifact = TranscriptArtifact()
        artifact.$episode.id = try episode.requireID()
        artifact.renditionID = input.renditionID
        artifact.locale = input.locale
        artifact.model = input.model
        artifact.segmentsJSON = input.segmentsJSON
        artifact.segmentFingerprintsJSON = input.segmentFingerprintsJSON
        artifact.textHash = input.textHash
        try await artifact.save(on: req.db)
        if let fingerprint = input.fingerprint {
            _ = try await saveFingerprint(fingerprint, episodeID: episode.requireID(), on: req.db)
        }
        return artifact
    }

    func uploadFingerprint(req: Request) async throws -> FingerprintArtifact {
        let episode = try await findEpisode(req)
        let input = try req.content.decode(FingerprintUpload.self)
        return try await saveFingerprint(input, episodeID: episode.requireID(), on: req.db)
    }

    private func saveFingerprint(_ input: FingerprintUpload, episodeID: UUID, on db: any Database) async throws -> FingerprintArtifact {
        let artifact = FingerprintArtifact()
        artifact.$episode.id = episodeID
        artifact.renditionID = input.renditionID
        artifact.algorithm = input.algorithm
        artifact.chunkDuration = input.chunkDuration
        artifact.chunksJSON = input.chunksJSON
        artifact.audioHash = input.audioHash
        try await artifact.save(on: db)
        return artifact
    }

    func uploadChapters(req: Request) async throws -> ChapterArtifact {
        let episode = try await findEpisode(req)
        let input = try req.content.decode(ChaptersUpload.self)
        let artifact = ChapterArtifact()
        artifact.$episode.id = try episode.requireID()
        artifact.source = input.source
        artifact.chaptersJSON = input.chaptersJSON
        try await artifact.save(on: req.db)
        return artifact
    }

    private func ensureWorkerJob(episodeID: UUID, kind: String, priority: Int, on db: any Database) async throws {
        let activeJobs = try await WorkerJob.query(on: db)
            .filter(\.$episode.$id == episodeID)
            .filter(\.$kind == kind)
            .all()
            .filter { $0.status == "pending" || $0.status == "claimed" }
        if let existing = activeJobs.first {
            if existing.status == "pending" {
                existing.priority = max(existing.priority, priority)
                try await existing.save(on: db)
            }
            return
        }
        try await WorkerJob(episodeID: episodeID, kind: kind, priority: priority).save(on: db)
    }

    private func transcriptReadyForAlignment(episodeID: UUID, on db: any Database) async throws -> Bool {
        guard let transcript = try await TranscriptArtifact.query(on: db)
            .filter(\.$episode.$id == episodeID)
            .sort(\.$createdAt, .descending)
            .first() else {
            return false
        }
        return transcript.segmentFingerprintsJSON?.isEmpty == false
    }

    private func artifactExists(episodeID: UUID, kind: String, on db: any Database) async throws -> Bool {
        switch kind {
        case "transcript":
            return try await transcriptReadyForAlignment(episodeID: episodeID, on: db)
        case "fingerprint":
            return try await FingerprintArtifact.query(on: db)
                .filter(\.$episode.$id == episodeID)
                .first() != nil
        case "chapters":
            return try await ChapterArtifact.query(on: db)
                .filter(\.$episode.$id == episodeID)
                .first() != nil
        default:
            return false
        }
    }

    private func findEpisode(_ req: Request) async throws -> Episode {
        guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
        if let uuid = UUID(uuidString: id), let episode = try await Episode.find(uuid, on: req.db) { return episode }
        if let episode = try await Episode.query(on: req.db).filter(\.$stableID == id).first() { return episode }
        throw Abort(.notFound)
    }
}

struct ArtifactDemandRequest: Content {
    let transcript: Bool?
    let chapters: Bool?
    let fingerprint: Bool?
}

struct ArtifactRequestResponse: Content {
    let episodeID: String
    let transcriptCount: Int
    let chapterCount: Int
    let fingerprintCount: Int
}

struct TranscriptUpload: Content {
    let renditionID: String?
    let locale: String
    let model: String
    let segmentsJSON: String
    let segmentFingerprintsJSON: String?
    let textHash: String
    let fingerprint: FingerprintUpload?
}

struct FingerprintUpload: Content {
    let renditionID: String?
    let algorithm: String
    let chunkDuration: Double
    let chunksJSON: String
    let audioHash: String?
}

struct ChaptersUpload: Content {
    let source: String
    let chaptersJSON: String
}
