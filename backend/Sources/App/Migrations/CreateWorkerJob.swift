import Fluent

struct CreateWorkerJob: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("worker_jobs")
            .id()
            .field("episode_id", .uuid, .required, .references("episodes", "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("status", .string, .required)
            .field("priority", .int, .required)
            .field("claimed_by", .string)
            .field("claimed_at", .datetime)
            .field("completed_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("worker_jobs").delete()
    }
}
