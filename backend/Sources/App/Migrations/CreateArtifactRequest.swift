import Fluent

struct CreateArtifactRequest: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("artifact_requests")
            .id()
            .field("episode_id", .uuid, .required, .references("episodes", "id", onDelete: .cascade))
            .field("transcript_count", .int, .required)
            .field("chapter_count", .int, .required)
            .field("fingerprint_count", .int, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "episode_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("artifact_requests").delete()
    }
}
