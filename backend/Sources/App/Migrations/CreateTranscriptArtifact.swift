import Fluent

struct CreateTranscriptArtifact: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("transcript_artifacts")
            .id()
            .field("episode_id", .uuid, .required, .references("episodes", "id", onDelete: .cascade))
            .field("rendition_id", .string)
            .field("locale", .string, .required)
            .field("model", .string, .required)
            .field("segments_json", .string, .required)
            .field("text_hash", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("transcript_artifacts").delete()
    }
}
