import Fluent
import FluentPostgresDriver
import Vapor

/// Ranked episode search. On Postgres it uses a weighted full-text index so that
/// title matches outrank summary matches, which in turn outrank transcript-only
/// matches, and returns a highlighted snippet (the sentence around the match).
/// On other databases (the SQLite test backend) it falls back to a substring
/// match with the same title-first ordering and a Swift-built snippet.
struct EpisodeSearchService: Sendable {
    /// Markers used to wrap matched terms in the returned snippet. The client
    /// highlights the text between them.
    static let highlightStart = "\u{00AB}" // «
    static let highlightEnd = "\u{00BB}"   // »

    func search(term: String, limit: Int, on db: any Database) async throws -> [EpisodeResponse] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let sql = db as? any SQLDatabase, sql.dialect.name == "postgresql" {
            return try await postgresSearch(term: trimmed, limit: limit, on: sql)
        }
        return try await fallbackSearch(term: trimmed, limit: limit, on: db)
    }

    // MARK: - Postgres full-text search

    private struct PostgresRow: Decodable {
        let id: UUID
        let podcast_id: UUID
        let podcast_stable_id: String
        let stable_id: String
        let title: String
        let summary: String?
        let audio_url: String
        let image_url: String?
        let podcast_image_url: String?
        let published_at: Date?
        let duration: Double?
        let in_title: Bool
        let in_summary: Bool
        let snippet: String?
    }

    private func postgresSearch(term: String, limit: Int, on sql: any SQLDatabase) async throws -> [EpisodeResponse] {
        let headlineOptions = "StartSel=\(Self.highlightStart),StopSel=\(Self.highlightEnd),MaxFragments=1,MinWords=7,MaxWords=24,ShortWord=2,FragmentDelimiter= … "
        let rows = try await sql.raw("""
        SELECT e.id, e.podcast_id, e.stable_id, e.title, e.summary, e.audio_url,
               e.image_url, e.published_at, e.duration,
               p.stable_id AS podcast_stable_id, p.image_url AS podcast_image_url,
               (to_tsvector('english', coalesce(e.title, '')) @@ query) AS in_title,
               (to_tsvector('english', coalesce(e.summary, '')) @@ query) AS in_summary,
               ts_headline('english',
                   coalesce(NULLIF(e.transcript_text, ''), e.summary, ''),
                   query, \(bind: headlineOptions)) AS snippet
        FROM episodes e
        JOIN podcasts p ON p.id = e.podcast_id,
             websearch_to_tsquery('english', \(bind: term)) query
        WHERE e.search_vector @@ query
        ORDER BY ts_rank('{0.1, 0.2, 0.4, 1.0}'::real[], e.search_vector, query) DESC,
                 e.published_at DESC NULLS LAST
        LIMIT \(bind: limit)
        """).all(decoding: PostgresRow.self)

        return rows.map { row in
            let field: String
            if row.in_title { field = "title" }
            else if row.in_summary { field = "summary" }
            else { field = "transcript" }
            // Only surface a snippet when the match is in the body text; a
            // title-only match needs no surrounding-sentence context.
            let snippet = (field == "title") ? nil : sanitizedSnippet(row.snippet)
            return EpisodeResponse(
                id: row.id,
                podcastStableID: row.podcast_stable_id,
                stableID: row.stable_id,
                title: row.title,
                summary: row.summary,
                audioURL: row.audio_url,
                imageURL: row.image_url ?? row.podcast_image_url,
                publishedAt: row.published_at,
                duration: row.duration,
                matchSnippet: snippet,
                matchField: field
            )
        }
    }

    private func sanitizedSnippet(_ snippet: String?) -> String? {
        guard let snippet else { return nil }
        let collapsed = snippet
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // ts_headline returns the whole text (no markers) when the match isn't in
        // this column; drop those so we don't show an unhighlighted excerpt.
        guard collapsed.contains(Self.highlightStart) else { return nil }
        return collapsed.isEmpty ? nil : collapsed
    }

    // MARK: - Fallback substring search (SQLite tests)

    private func fallbackSearch(term: String, limit: Int, on db: any Database) async throws -> [EpisodeResponse] {
        let needle = term.lowercased()
        let candidates = try await Episode.query(on: db)
            .with(\.$podcast)
            .group(.or) { group in
                group.filter(\.$title ~~ term)
                group.filter(\.$summary ~~ term)
                group.filter(\.$transcriptText ~~ term)
            }
            .sort(\.$publishedAt, .descending)
            .limit(limit)
            .all()

        let scored = candidates.map { episode -> (EpisodeResponse, Int) in
            let inTitle = episode.title.lowercased().contains(needle)
            let inSummary = episode.summary?.lowercased().contains(needle) ?? false
            let field: String
            let rank: Int
            if inTitle { field = "title"; rank = 0 }
            else if inSummary { field = "summary"; rank = 1 }
            else { field = "transcript"; rank = 2 }
            let snippet = (field == "title")
                ? nil
                : SearchSnippet.make(from: field == "summary" ? episode.summary : episode.transcriptText, matching: term)
            return (EpisodeResponse(episode: episode, matchSnippet: snippet, matchField: field), rank)
        }
        return scored.sorted { $0.1 < $1.1 }.map(\.0)
    }
}

/// Builds a highlighted, sentence-sized excerpt around the first match of `term`
/// in `text`, wrapping the match in the highlight markers.
enum SearchSnippet {
    static func make(from text: String?, matching term: String, window: Int = 90) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let lowerText = text.lowercased()
        let lowerTerm = term.lowercased()
        guard let range = lowerText.range(of: lowerTerm) else { return nil }

        let lower = text.index(range.lowerBound, offsetBy: -window, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: window, limitedBy: text.endIndex) ?? text.endIndex
        var excerpt = String(text[lower..<upper])

        // Re-find the match within the excerpt to insert markers safely.
        if let local = excerpt.range(of: term, options: .caseInsensitive) {
            excerpt.replaceSubrange(local, with: "\(EpisodeSearchService.highlightStart)\(excerpt[local])\(EpisodeSearchService.highlightEnd)")
        }
        let prefix = lower > text.startIndex ? "… " : ""
        let suffix = upper < text.endIndex ? " …" : ""
        return prefix + excerpt.trimmingCharacters(in: .whitespacesAndNewlines) + suffix
    }
}
