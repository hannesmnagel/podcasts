import Fluent

struct CreateFingerprintArtifact: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("fingerprint_artifacts")
            .id()
            .field("episode_id", .uuid, .required, .references("episodes", "id", onDelete: .cascade))
            .field("rendition_id", .string)
            .field("algorithm", .string, .required)
            .field("chunk_duration", .double, .required)
            .field("chunks_json", .string, .required)
            .field("audio_hash", .string)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("fingerprint_artifacts").delete()
    }
}
