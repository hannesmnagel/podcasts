import Fluent

struct AddTranscriptSegmentFingerprints: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("transcript_artifacts")
            .field("segment_fingerprints_json", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("transcript_artifacts")
            .deleteField("segment_fingerprints_json")
            .update()
    }
}
