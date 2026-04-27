import Fluent

struct CreatePodcastDemand: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("podcast_demands")
            .id()
            .field("podcast_id", .uuid, .required, .references("podcasts", "id", onDelete: .cascade))
            .field("transcript_requests", .int, .required)
            .field("chapter_requests", .int, .required)
            .field("fingerprint_requests", .int, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "podcast_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("podcast_demands").delete()
    }
}
