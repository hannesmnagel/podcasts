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
            guard let candidate = try await WorkerJob.query(on: req.db)
                .filter(\.$status == "pending")
                .sort(\.$priority, .descending)
                .sort(\.$createdAt, .ascending)
                .first() else { throw Abort(.noContent) }
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
