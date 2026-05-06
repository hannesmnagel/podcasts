import Fluent
import Vapor

final class FingerprintArtifact: Model, Content, @unchecked Sendable {
    static let schema = "fingerprint_artifacts"

    @ID(key: .id) var id: UUID?
    @Parent(key: "episode_id") var episode: Episode
    @Field(key: "rendition_id") var renditionID: String?
    @Field(key: "algorithm") var algorithm: String
    @Field(key: "chunk_duration") var chunkDuration: Double
    @Field(key: "chunks_json") var chunksJSON: String
    @Field(key: "audio_hash") var audioHash: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
}
