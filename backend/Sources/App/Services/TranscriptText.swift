import Foundation

/// Extracts a plain-text rendition of a transcript from its segments JSON so it
/// can be indexed for full-text search. The worker stores transcripts as an
/// array of timed segments; for search we only need the concatenated spoken text.
enum TranscriptText {
    private struct Segment: Decodable {
        let text: String?
    }

    /// Returns the concatenated, whitespace-normalized spoken text, or `nil` when
    /// the JSON cannot be decoded or contains no usable text.
    static func plainText(fromSegmentsJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let segments = try? JSONDecoder().decode([Segment].self, from: data) else {
            return nil
        }
        let joined = segments
            .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let collapsed = joined
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}
