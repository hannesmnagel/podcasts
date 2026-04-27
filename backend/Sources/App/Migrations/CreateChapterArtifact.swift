import Fluent

struct CreateChapterArtifact: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("chapter_artifacts")
            .id()
            .field("episode_id", .uuid, .required, .references("episodes", "id", onDelete: .cascade))
            .field("source", .string, .required)
            .field("chapters_json", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("chapter_artifacts").delete()
    }
}
