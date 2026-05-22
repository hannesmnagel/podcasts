import Fluent

struct AddWorkerJobRetryBackoff: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("worker_jobs")
            .field("retry_count", .int, .required, .sql(.default(0)))
            .field("next_attempt_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("worker_jobs")
            .deleteField("retry_count")
            .deleteField("next_attempt_at")
            .update()
    }
}
