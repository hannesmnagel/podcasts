import Fluent
import Vapor

final class PodcastDemand: Model, Content, @unchecked Sendable {
    static let schema = "podcast_demands"

    @ID(key: .id) var id: UUID?
    @Parent(key: "podcast_id") var podcast: Podcast
    @Field(key: "transcript_requests") var transcriptRequests: Int
    @Field(key: "chapter_requests") var chapterRequests: Int
    @Field(key: "fingerprint_requests") var fingerprintRequests: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(podcastID: UUID) {
        self.$podcast.id = podcastID
        self.transcriptRequests = 0
        self.chapterRequests = 0
        self.fingerprintRequests = 0
    }

    var priorityScore: Int {
        transcriptRequests * 3 + chapterRequests * 2 + fingerprintRequests
    }
}
