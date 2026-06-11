import Fluent
import FluentPostgresDriver
import Foundation

/// Adds a denormalized `transcript_text` column to episodes plus, on Postgres, a
/// weighted full-text `search_vector` (title = A, summary = B, transcript = C)
/// backed by a GIN index. This powers ranked, snippet-highlighted search that
/// prefers title matches over transcript-only matches.
///
/// Every step is idempotent (IF NOT EXISTS / DROP-then-ADD) so a partial failure
/// followed by a restart re-runs cleanly instead of crash-looping. The
/// transcript portion of the vector is position-stripped and length-bounded so a
/// very long transcript can never exceed Postgres's 1 MB tsvector limit.
struct AddEpisodeSearchIndex: AsyncMigration {
    // Bound the transcript text fed into the tsvector (600k characters) so the
    // vector stays well under Postgres's 1 MB limit even for very long episodes;
    // this covers essentially every episode in full.

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            // SQLite (tests): a plain column is all the fallback search needs.
            try await database.schema("episodes")
                .field("transcript_text", .string)
                .update()
            return
        }

        try await sql.raw("ALTER TABLE episodes ADD COLUMN IF NOT EXISTS transcript_text text").run()

        // Backfill transcript_text from the most recent transcript per episode so
        // existing transcripts are immediately searchable.
        try await backfillTranscriptText(on: sql)

        // Recreate the generated column unconditionally so we always end up with
        // the size-safe definition, regardless of any earlier partial attempt.
        try await sql.raw("ALTER TABLE episodes DROP COLUMN IF EXISTS search_vector").run()
        try await sql.raw("""
        ALTER TABLE episodes ADD COLUMN search_vector tsvector
            GENERATED ALWAYS AS (
                setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
                setweight(to_tsvector('english', coalesce(summary, '')), 'B') ||
                setweight(strip(to_tsvector('english', left(coalesce(transcript_text, ''), 600000))), 'C')
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
            try await sql.raw("ALTER TABLE episodes DROP COLUMN IF EXISTS transcript_text").run()
            return
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
