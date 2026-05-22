import Fluent
import Vapor

struct WorkerController: RouteCollection {
    private let transcriptPriorityBoost = 1_000_000
    private let recencyPriorityWindowDays = 30
    private let baseRetryDelaySeconds = 60
    private let maxRetryDelaySeconds = 3600
    private let maxRetryAttempts = 8

    func boot(routes: any RoutesBuilder) throws {
        let workers = routes.grouped("worker")
        workers.post("jobs", "claim", use: claim)
        workers.post("jobs", ":id", "complete", use: complete)
        workers.post("jobs", ":id", "fail", use: fail)
    }

    func claim(req: Request) async throws -> ClaimedWorkerJobResponse {
        let input = try req.content.decode(ClaimJobRequest.self)
        let timeoutSeconds = Environment.get("WORKER_JOB_TIMEOUT_SECONDS")
            .flatMap(Double.init) ?? 7_200
        let cutoff = Date().addingTimeInterval(-timeoutSeconds)

        // Opportunistically reap stale claims on each claim request so dead
        // claims cannot throttle throughput for hours until the periodic reaper runs.
        try await WorkerJob.query(on: req.db)
            .filter(\.$status == "claimed")
            .filter(\.$claimedAt < cutoff)
            .set(\.$status, to: "pending")
            .set(\.$claimedBy, to: nil)
            .set(\.$claimedAt, to: nil)
            .update()

        let activeClaimsForWorker = try await WorkerJob.query(on: req.db)
            .filter(\.$status == "claimed")
            .filter(\.$claimedBy == input.workerID)
            .all()
        let hasActiveTranscript = activeClaimsForWorker.contains {
            $0.kind == "transcript" && (($0.claimedAt ?? .distantFuture) >= cutoff)
        }

        var allowedKinds = input.kinds
        if hasActiveTranscript {
            if let kinds = allowedKinds {
                allowedKinds = kinds.filter { $0 != "transcript" }
            } else {
                allowedKinds = ["chapters"]
            }
        }

        for _ in 0..<3 {
            var pending = try await nextPendingJob(kinds: allowedKinds, on: req.db)
            if pending == nil {
                if hasActiveTranscript == false {
                    pending = try await seedBacklogTranscriptJob(on: req.db)
                }
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
        job.nextAttemptAt = nil
        try await job.save(on: req.db)
        return try ClaimedWorkerJobResponse(job: job)
    }

    func fail(req: Request) async throws -> ClaimedWorkerJobResponse {
        let job = try await findJob(req)
        let input = try req.content.decode(FailJobRequest.self)
        if input.retry == false {
            job.status = "failed"
            job.nextAttemptAt = nil
        } else if job.retryCount >= maxRetryAttempts {
            job.status = "failed"
            job.nextAttemptAt = nil
        } else {
            job.retryCount += 1
            job.status = "pending"
            job.claimedBy = nil
            job.claimedAt = nil
            let exponent = max(0, job.retryCount - 1)
            let multiplier = 1 << min(exponent, 30)
            let delay = min(maxRetryDelaySeconds, baseRetryDelaySeconds * multiplier)
            job.nextAttemptAt = Date().addingTimeInterval(TimeInterval(delay))
        }
        try await job.save(on: req.db)
        return try ClaimedWorkerJobResponse(job: job)
    }

    private func nextPendingJob(kinds: [String]?, on db: any Database) async throws -> WorkerJob? {
        let now = Date()
        var query = WorkerJob.query(on: db)
            .filter(\.$status == "pending")
            .group(.or) { group in
                group.filter(\.$nextAttemptAt == nil)
                group.filter(\.$nextAttemptAt <= now)
            }
            .with(\.$episode)
        if let kinds, !kinds.isEmpty {
            query = query.group(.or) { group in
                for kind in kinds {
                    group.filter(\.$kind == kind)
                }
            }
        }
        let pending = try await query.all()
        let episodeIDs = Set(pending.map(\.$episode.id))
        let artifactRequests = try await ArtifactRequest.query(on: db)
            .all()
            .filter { episodeIDs.contains($0.$episode.id) }
        let requestsByEpisodeID = Dictionary(uniqueKeysWithValues: artifactRequests.map { ($0.$episode.id, $0.transcriptCount) })

        let podcastIDs = Set(pending.map { $0.episode.$podcast.id })
        let podcastDemands = try await PodcastDemand.query(on: db)
            .all()
            .filter { podcastIDs.contains($0.$podcast.id) }
        let demandByPodcastID = Dictionary(uniqueKeysWithValues: podcastDemands.map { ($0.$podcast.id, $0.priorityScore) })

        return pending.max { lhs, rhs in
            jobSortKey(
                lhs,
                transcriptRequests: requestsByEpisodeID[lhs.$episode.id] ?? 0,
                podcastDemandScore: demandByPodcastID[lhs.episode.$podcast.id] ?? 0
            ) < jobSortKey(
                rhs,
                transcriptRequests: requestsByEpisodeID[rhs.$episode.id] ?? 0,
                podcastDemandScore: demandByPodcastID[rhs.episode.$podcast.id] ?? 0
            )
        }
    }

    private func jobSortKey(_ job: WorkerJob, transcriptRequests: Int, podcastDemandScore: Int) -> JobSortKey {
        let episodePublishedAt = job.episode.publishedAt ?? .distantPast
        let kindBoost = job.kind == "transcript" ? transcriptPriorityBoost : 0
        let recencyBoost = recencyPriority(for: episodePublishedAt)
        let isNew = recencyBoost > 0
        let hasEpisodeRequest = transcriptRequests > 0
        let podcastIsHot = podcastDemandScore > 0
        let tier: Int = {
            if isNew && hasEpisodeRequest { return 3 }
            if isNew && podcastIsHot { return 2 }
            if !isNew && hasEpisodeRequest { return 1 }
            return 0
        }()
        let createdAt = job.createdAt ?? .distantPast
        let id = job.id ?? UUID()
        return JobSortKey(
            tier: tier,
            recencyBoost: recencyBoost,
            transcriptRequests: transcriptRequests,
            score: job.priority + kindBoost + podcastDemandScore,
            publishedAt: episodePublishedAt,
            createdAt: createdAt,
            id: id
        )
    }

    private func recencyPriority(for publishedAt: Date) -> Int {
        let daysOld = Calendar.current.dateComponents([.day], from: publishedAt, to: Date()).day ?? recencyPriorityWindowDays
        let clampedDays = max(0, min(recencyPriorityWindowDays, daysOld))
        let remaining = recencyPriorityWindowDays - clampedDays
        return remaining * 1_000
    }

    private func seedBacklogTranscriptJob(on db: any Database) async throws -> WorkerJob? {
        let episodeIDsWithDemand = try await podcastIDsSortedByDemand(on: db)
        if !episodeIDsWithDemand.isEmpty {
            for podcastID in episodeIDsWithDemand {
                let demandedEpisodes = try await Episode.query(on: db)
                    .filter(\.$podcast.$id == podcastID)
                    .sort(\.$publishedAt, .descending)
                    .sort(\.$createdAt, .descending)
                    .all()
                for episode in demandedEpisodes {
                    let episodeID = try episode.requireID()
                    guard try await needsAlignmentTranscriptRefresh(episodeID: episodeID, on: db),
                          try await hasBlockingTranscriptJob(episodeID: episodeID, on: db) == false else {
                        continue
                    }
                    let boost = recencyPriority(for: episode.publishedAt ?? .distantPast)
                    let job = WorkerJob(episodeID: episodeID, kind: "transcript", priority: transcriptPriorityBoost + boost)
                    try await job.save(on: db)
                    return job
                }
            }
        }

        let episodes = try await Episode.query(on: db)
            .sort(\.$publishedAt, .descending)
            .sort(\.$createdAt, .descending)
            .all()
        for episode in episodes {
            let episodeID = try episode.requireID()
            guard try await needsAlignmentTranscriptRefresh(episodeID: episodeID, on: db),
                  try await hasBlockingTranscriptJob(episodeID: episodeID, on: db) == false else {
                continue
            }
            let boost = recencyPriority(for: episode.publishedAt ?? .distantPast)
            let job = WorkerJob(episodeID: episodeID, kind: "transcript", priority: transcriptPriorityBoost + boost)
            try await job.save(on: db)
            return job
        }
        return nil
    }

    private func podcastIDsSortedByDemand(on db: any Database) async throws -> [UUID] {
        let demands = try await PodcastDemand.query(on: db)
            .sort(\.$transcriptRequests, .descending)
            .sort(\.$chapterRequests, .descending)
            .sort(\.$fingerprintRequests, .descending)
            .all()
        return demands.map(\.$podcast.id)
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
        return jobs.contains { $0.status == "pending" || $0.status == "claimed" }
    }

    private func findJob(_ req: Request) async throws -> WorkerJob {
        guard let id = req.parameters.get("id", as: UUID.self),
              let job = try await WorkerJob.query(on: req.db).with(\.$episode).filter(\.$id == id).first() else {
            throw Abort(.notFound)
        }
        return job
    }
}

private struct JobSortKey: Comparable {
    let tier: Int
    let recencyBoost: Int
    let transcriptRequests: Int
    let score: Int
    let publishedAt: Date
    let createdAt: Date
    let id: UUID

    static func < (lhs: JobSortKey, rhs: JobSortKey) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        if lhs.recencyBoost != rhs.recencyBoost { return lhs.recencyBoost < rhs.recencyBoost }
        if lhs.transcriptRequests != rhs.transcriptRequests { return lhs.transcriptRequests < rhs.transcriptRequests }
        if lhs.score != rhs.score { return lhs.score < rhs.score }
        if lhs.publishedAt != rhs.publishedAt { return lhs.publishedAt < rhs.publishedAt }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct ClaimJobRequest: Content {
    let workerID: String
    let kinds: [String]?
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
