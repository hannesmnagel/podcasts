import Fluent
import Vapor

final class TranscriptArtifact: Model, Content, @unchecked Sendable {
    static let schema = "transcript_artifacts"

    @ID(key: .id) var id: UUID?
    @Parent(key: "episode_id") var episode: Episode
    @Field(key: "rendition_id") var renditionID: String?
    @Field(key: "locale") var locale: String
    @Field(key: "model") var model: String
    @Field(key: "segments_json") var segmentsJSON: String
    @Field(key: "text_hash") var textHash: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
}
