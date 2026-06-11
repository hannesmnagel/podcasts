import Fluent
import FluentPostgresDriver
import Foundation

/// Adds a denormalized `transcript_text` column to episodes plus, on Postgres, a
/// weighted full-text `search_vector` (title = A, summary = B, transcript = C)
/// backed by a GIN index. This powers ranked, snippet-highlighted search that
/// prefers title matches over transcript-only matches.
struct AddEpisodeSearchIndex: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // The plain-text transcript column exists on every backend (SQLite tests
        // included) so the search code can use a single column.
        try await database.schema("episodes")
            .field("transcript_text", .string)
            .update()

        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            return
        }

        // Backfill transcript_text from the most recent transcript per episode
        // before the generated column is created so existing transcripts are
        // immediately searchable.
        try await backfillTranscriptText(on: sql)

        try await sql.raw("""
        ALTER TABLE episodes ADD COLUMN IF NOT EXISTS search_vector tsvector
            GENERATED ALWAYS AS (
                setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
                setweight(to_tsvector('english', coalesce(summary, '')), 'B') ||
                setweight(to_tsvector('english', coalesce(transcript_text, '')), 'C')
            ) STORED
        """).run()

        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS episodes_search_vector_idx
            ON episodes USING GIN (search_vector)
        """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("DROP INDEX IF EXISTS episodes_search_vector_idx").run()
            try await sql.raw("ALTER TABLE episodes DROP COLUMN IF EXISTS search_vector").run()
        }
        try await database.schema("episodes")
            .deleteField("transcript_text")
            .update()
    }

    private struct LatestTranscriptRow: Decodable {
        let episode_id: UUID
        let segments_json: String
    }

    private func backfillTranscriptText(on sql: any SQLDatabase) async throws {
        let rows = try await sql.raw("""
        SELECT DISTINCT ON (episode_id) episode_id, segments_json
        FROM transcript_artifacts
        ORDER BY episode_id, created_at DESC
        """).all(decoding: LatestTranscriptRow.self)

        for row in rows {
            guard let text = TranscriptText.plainText(fromSegmentsJSON: row.segments_json) else { continue }
            try await sql.raw("""
            UPDATE episodes SET transcript_text = \(bind: text) WHERE id = \(bind: row.episode_id)
            """).run()
        }
    }
}
