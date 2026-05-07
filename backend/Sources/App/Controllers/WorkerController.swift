import Fluent
import Vapor

struct WorkerController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let workers = routes.grouped("worker")
        workers.post("jobs", "claim", use: claim)
        workers.post("jobs", ":id", "complete", use: complete)
        workers.post("jobs", ":id", "fail", use: fail)
    }

    func claim(req: Request) async throws -> ClaimedWorkerJobResponse {
        let input = try req.content.decode(ClaimJobRequest.self)
        for _ in 0..<3 {
            var pending = try await nextPendingTranscriptJob(on: req.db)
            if pending == nil {
                pending = try await seedBacklogTranscriptJob(on: req.db)
            }
            guard let candidate = pending else { throw Abort(.noContent) }
            let candidateID = try candidate.requireID()
            try await WorkerJob.query(on: req.db)
                .filter(\.$id == candidateID)
                .filter(\.$status == "pending")
                .set(\.$status, to: "claimed")
                .set(\.$claimedBy, to: input.workerID)
                .set(\.$claimedAt, to: Date())
                .update()
            if let claimed = try await WorkerJob.query(on: req.db)
                .with(\.$episode)
                .filter(\.$id == candidateID)
                .filter(\.$status == "claimed")
                .filter(\.$claimedBy == input.workerID)
                .first() {
                return try ClaimedWorkerJobResponse(job: claimed)
            }
        }
        throw Abort(.noContent)
    }

    func complete(req: Request) async throws -> ClaimedWorkerJobResponse {
        let job = try await findJob(req)
        job.status = "completed"
        job.completedAt = Date()
        try await job.save(on: req.db)
        return try ClaimedWorkerJobResponse(job: job)
    }

    func fail(req: Request) async throws -> ClaimedWorkerJobResponse {
        let job = try await findJob(req)
        let input = try req.content.decode(FailJobRequest.self)
        if input.retry ?? false {
            job.status = "pending"
            job.claimedBy = nil
            job.claimedAt = nil
        } else {
            job.status = "failed"
        }
        try await job.save(on: req.db)
        return try ClaimedWorkerJobResponse(job: job)
    }

    private func nextPendingTranscriptJob(on db: any Database) async throws -> WorkerJob? {
        try await WorkerJob.query(on: db)
            .filter(\.$status == "pending")
            .filter(\.$kind == "transcript")
            .sort(\.$priority, .descending)
            .sort(\.$createdAt, .ascending)
            .first()
    }

    private func seedBacklogTranscriptJob(on db: any Database) async throws -> WorkerJob? {
        let demands = try await PodcastDemand.query(on: db)
            .sort(\.$transcriptRequests, .descending)
            .sort(\.$fingerprintRequests, .descending)
            .all()
        for demand in demands {
            if let job = try await seedBacklogTranscriptJob(podcastID: demand.$podcast.id, priority: max(1, demand.priorityScore), on: db) {
                return job
            }
        }

        let podcasts = try await Podcast.query(on: db).all()
        for podcast in podcasts {
            if let podcastID = podcast.id,
               let job = try await seedBacklogTranscriptJob(podcastID: podcastID, priority: 0, on: db) {
                return job
            }
        }
        return nil
    }

    private func seedBacklogTranscriptJob(podcastID: UUID, priority: Int, on db: any Database) async throws -> WorkerJob? {
        let episodes = try await Episode.query(on: db)
            .filter(\.$podcast.$id == podcastID)
            .sort(\.$publishedAt, .descending)
            .sort(\.$createdAt, .descending)
            .all()
        for episode in episodes {
            let episodeID = try episode.requireID()
            guard try await needsAlignmentTranscriptRefresh(episodeID: episodeID, on: db),
                  try await hasBlockingTranscriptJob(episodeID: episodeID, on: db) == false else {
                continue
            }
            let job = WorkerJob(episodeID: episodeID, kind: "transcript", priority: priority)
            try await job.save(on: db)
            return job
        }
        return nil
    }

    private func needsAlignmentTranscriptRefresh(episodeID: UUID, on db: any Database) async throws -> Bool {
        guard let transcript = try await TranscriptArtifact.query(on: db)
            .filter(\.$episode.$id == episodeID)
            .sort(\.$createdAt, .descending)
            .first() else {
            return true
        }
        return transcript.segmentFingerprintsJSON?.isEmpty != false
    }

    private func hasBlockingTranscriptJob(episodeID: UUID, on db: any Database) async throws -> Bool {
        let jobs = try await WorkerJob.query(on: db)
            .filter(\.$episode.$id == episodeID)
            .filter(\.$kind == "transcript")
            .all()
        return jobs.contains { $0.status == "pending" || $0.status == "claimed" || $0.status == "failed" }
    }

    private func findJob(_ req: Request) async throws -> WorkerJob {
        guard let id = req.parameters.get("id", as: UUID.self),
              let job = try await WorkerJob.query(on: req.db).with(\.$episode).filter(\.$id == id).first() else {
            throw Abort(.notFound)
        }
        return job
    }
}

struct ClaimJobRequest: Content {
    let workerID: String
}

struct FailJobRequest: Content {
    let retry: Bool?
}

struct ClaimedWorkerJobResponse: Content {
    let id: UUID
    let kind: String
    let priority: Int
    let episode: Episode

    init(job: WorkerJob) throws {
        self.id = try job.requireID()
        self.kind = job.kind
        self.priority = job.priority
        self.episode = job.episode
    }
}
