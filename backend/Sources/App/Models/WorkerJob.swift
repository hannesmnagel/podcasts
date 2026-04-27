import Fluent
import Vapor

final class WorkerJob: Model, Content, @unchecked Sendable {
    static let schema = "worker_jobs"

    @ID(key: .id) var id: UUID?
    @Parent(key: "episode_id") var episode: Episode
    @Field(key: "kind") var kind: String
    @Field(key: "status") var status: String
    @Field(key: "priority") var priority: Int
    @Field(key: "claimed_by") var claimedBy: String?
    @Field(key: "claimed_at") var claimedAt: Date?
    @Field(key: "completed_at") var completedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(episodeID: UUID, kind: String, priority: Int) {
        self.$episode.id = episodeID
        self.kind = kind
        self.status = "pending"
        self.priority = priority
    }
}
