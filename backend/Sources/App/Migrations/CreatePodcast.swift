import Fluent

struct CreatePodcast: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("podcasts")
            .id()
            .field("stable_id", .string, .required)
            .field("feed_url", .string, .required)
            .field("title", .string, .required)
            .field("description", .string)
            .field("image_url", .string)
            .field("etag", .string)
            .field("last_modified", .string)
            .field("last_crawled_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "stable_id")
            .unique(on: "feed_url")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("podcasts").delete()
    }
}
