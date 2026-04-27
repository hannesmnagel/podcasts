import Fluent

struct CreateEpisode: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("episodes")
            .id()
            .field("podcast_id", .uuid, .required, .references("podcasts", "id", onDelete: .cascade))
            .field("stable_id", .string, .required)
            .field("guid", .string)
            .field("title", .string, .required)
            .field("summary", .string)
            .field("audio_url", .string, .required)
            .field("image_url", .string)
            .field("published_at", .datetime)
            .field("duration", .double)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "stable_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("episodes").delete()
    }
}
