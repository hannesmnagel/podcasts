import Fluent

struct AddWorkerJobRetryBackoff: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Add columns in separate ALTER statements: SQLite (used by the test
        // suite) only supports one ADD COLUMN per ALTER TABLE.
        try await database.schema("worker_jobs")
            .field("retry_count", .int, .required, .sql(.default(0)))
            .update()
        try await database.schema("worker_jobs")
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
