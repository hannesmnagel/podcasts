import Fluent
import Vapor

struct WorkerController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let workers = routes.grouped("worker")
        workers.post("jobs", "claim", use: claim)
        workers.post("jobs", ":id", "complete", use: complete)
    }

    func claim(req: Request) async throws -> WorkerJob {
        let input = try req.content.decode(ClaimJobRequest.self)
        guard let job = try await WorkerJob.query(on: req.db)
            .filter(\.$status == "pending")
            .sort(\.$priority, .descending)
            .sort(\.$createdAt, .ascending)
            .first() else { throw Abort(.noContent) }
        job.status = "claimed"
        job.claimedBy = input.workerID
        job.claimedAt = Date()
        try await job.save(on: req.db)
        return job
    }

    func complete(req: Request) async throws -> WorkerJob {
        guard let id = req.parameters.get("id", as: UUID.self), let job = try await WorkerJob.find(id, on: req.db) else { throw Abort(.notFound) }
        job.status = "completed"
        job.completedAt = Date()
        try await job.save(on: req.db)
        return job
    }
}

struct ClaimJobRequest: Content {
    let workerID: String
}
