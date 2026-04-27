import Fluent
import Vapor

final class Episode: Model, Content, @unchecked Sendable {
    static let schema = "episodes"

    @ID(key: .id) var id: UUID?
    @Parent(key: "podcast_id") var podcast: Podcast
    @Field(key: "stable_id") var stableID: String
    @Field(key: "guid") var guid: String?
    @Field(key: "title") var title: String
    @Field(key: "summary") var summary: String?
    @Field(key: "audio_url") var audioURL: String
    @Field(key: "image_url") var imageURL: String?
    @Field(key: "published_at") var publishedAt: Date?
    @Field(key: "duration") var duration: TimeInterval?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, podcastID: UUID, stableID: String, guid: String?, title: String, audioURL: String, publishedAt: Date? = nil, duration: TimeInterval? = nil) {
        self.id = id
        self.$podcast.id = podcastID
        self.stableID = stableID
        self.guid = guid
        self.title = title
        self.audioURL = audioURL
        self.publishedAt = publishedAt
        self.duration = duration
    }
}
