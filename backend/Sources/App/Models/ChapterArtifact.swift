import Fluent
import Vapor

final class ChapterArtifact: Model, Content, @unchecked Sendable {
    static let schema = "chapter_artifacts"

    @ID(key: .id) var id: UUID?
    @Parent(key: "episode_id") var episode: Episode
    @Field(key: "source") var source: String
    @Field(key: "chapters_json") var chaptersJSON: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
}
