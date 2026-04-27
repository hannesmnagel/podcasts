import Fluent
import Vapor

final class Podcast: Model, Content, @unchecked Sendable {
    static let schema = "podcasts"

    @ID(key: .id) var id: UUID?
    @Field(key: "stable_id") var stableID: String
    @Field(key: "feed_url") var feedURL: String
    @Field(key: "title") var title: String
    @Field(key: "description") var description: String?
    @Field(key: "image_url") var imageURL: String?
    @Field(key: "etag") var etag: String?
    @Field(key: "last_modified") var lastModified: String?
    @Field(key: "last_crawled_at") var lastCrawledAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @Children(for: \.$podcast) var episodes: [Episode]

    init() {}

    init(id: UUID? = nil, stableID: String, feedURL: String, title: String = "") {
        self.id = id
        self.stableID = stableID
        self.feedURL = feedURL
        self.title = title
    }
}
