import Fluent
import Vapor

final class ArtifactRequest: Model, Content, @unchecked Sendable {
    static let schema = "artifact_requests"

    @ID(key: .id) var id: UUID?
    @Parent(key: "episode_id") var episode: Episode
    @Field(key: "transcript_count") var transcriptCount: Int
    @Field(key: "chapter_count") var chapterCount: Int
    @Field(key: "fingerprint_count") var fingerprintCount: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, episodeID: UUID) {
        self.id = id
        self.$episode.id = episodeID
        self.transcriptCount = 0
        self.chapterCount = 0
        self.fingerprintCount = 0
    }
}
