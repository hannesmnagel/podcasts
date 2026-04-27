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
        guard let job = try await WorkerJob.query(on: req.db)
            .with(\.$episode)
            .filter(\.$status == "pending")
            .sort(\.$priority, .descending)
            .sort(\.$createdAt, .ascending)
            .first() else { throw Abort(.noContent) }
        job.status = "claimed"
        job.claimedBy = input.workerID
        job.claimedAt = Date()
        try await job.save(on: req.db)
        return try ClaimedWorkerJobResponse(job: job)
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
        job.status = "pending"
        job.claimedBy = nil
        job.claimedAt = nil
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
