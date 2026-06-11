import NaturalLanguage
import UIKit

/// On-device search intelligence: query normalization (lemmatization,
/// diacritic-folding), synonym/semantic expansion and semantic re-ranking of
/// results, all using Apple's `NaturalLanguage` framework so it works offline.
enum SearchIntelligence {
    // MARK: - Normalization

    /// Folds diacritics, lowercases and trims. Used for case/accent-insensitive
    /// substring matching ("pokemon" matches "Pokémon").
    static func fold(_ string: String) -> String {
        string.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lemmatized content tokens of a phrase, e.g. "running races" -> ["run", "race"].
    /// Stop words and punctuation are dropped so matching focuses on meaning.
    static func lemmas(of text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
        tagger.string = text
        var output: [String] = []
        let range = text.startIndex..<text.endIndex
        tagger.enumerateTags(in: range, unit: .word, scheme: .lemma, options: [.omitPunctuation, .omitWhitespace]) { tag, tokenRange in
            let raw = String(text[tokenRange])
            let lemma = tag?.rawValue.isEmpty == false ? tag!.rawValue : raw
            let folded = fold(lemma)
            if folded.count > 1, !stopWords.contains(folded) {
                output.append(folded)
            }
            return true
        }
        return output
    }

    /// Expands the query with semantically close words (synonym-ish) using the
    /// word embedding, so "car" can also surface "vehicle"/"automobile". Returns
    /// the original folded terms plus up to `perTerm` neighbours each.
    static func expandedTerms(for query: String, perTerm: Int = 3, maxDistance: Double = 0.85) -> [String] {
        let base = lemmas(of: query)
        guard let embedding = wordEmbedding else { return uniqued(base) }
        var terms = base
        for term in base {
            // NLEmbedding is not thread-safe; serialize access (see `similarity`).
            embeddingLock.lock()
            let neighbours = embedding.neighbors(for: term, maximumCount: perTerm)
            embeddingLock.unlock()
            for (word, distance) in neighbours where distance <= maxDistance {
                let folded = fold(word)
                if folded.count > 1, !stopWords.contains(folded) {
                    terms.append(folded)
                }
            }
        }
        return uniqued(terms)
    }

    // MARK: - Semantic ranking

    /// A semantic relevance score in roughly [0, 1] between a query and a piece
    /// of text (1 = identical meaning). Falls back to token overlap when the
    /// embedding is unavailable.
    static func similarity(query: String, text: String) -> Double {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !trimmedText.isEmpty else { return 0 }
        if let embedding = sentenceEmbedding {
            // NLEmbedding is not documented as thread-safe and crashes
            // (EXC_BAD_ACCESS) when `distance`/`neighbors` run concurrently on the
            // same instance — which happened because ranking runs in detached
            // tasks and searches can overlap. Serialize every access.
            embeddingLock.lock()
            let distance = embedding.distance(between: trimmedQuery, and: trimmedText, distanceType: .cosine)
            embeddingLock.unlock()
            // NLDistance for cosine is in [0, 2]; map to a [0, 1] similarity.
            // Guard against non-finite results for out-of-vocabulary input.
            guard distance.isFinite else { return tokenOverlap(query: trimmedQuery, text: trimmedText) }
            return max(0, 1 - distance / 2)
        }
        return tokenOverlap(query: trimmedQuery, text: trimmedText)
    }

    private static func tokenOverlap(query: String, text: String) -> Double {
        let q = Set(lemmas(of: query))
        guard !q.isEmpty else { return 0 }
        let t = Set(lemmas(of: text))
        return Double(q.intersection(t).count) / Double(q.count)
    }

    // MARK: - Embedding handles (loaded once)

    // NLEmbedding instances are loaded once but are NOT thread-safe to call;
    // `embeddingLock` serializes every distance/neighbor lookup across the
    // detached ranking tasks that use them.
    nonisolated(unsafe) private static let wordEmbedding: NLEmbedding? = NLEmbedding.wordEmbedding(for: .english)
    nonisolated(unsafe) private static let sentenceEmbedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)
    private static let embeddingLock = NSLock()

    private static func uniqued(_ terms: [String]) -> [String] {
        var seen: Set<String> = []
        return terms.filter { seen.insert($0).inserted }
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with",
        "is", "are", "was", "were", "be", "this", "that", "it", "as", "at",
        "by", "from", "about", "how", "what", "why", "who", "podcast", "episode"
    ]
}

/// Renders a search snippet (with « » highlight markers from the backend, or a
/// raw query to highlight locally) into an attributed string suitable for the
/// episode cell's summary label.
enum SearchHighlighter {
    static let markerStart = "\u{00AB}" // «
    static let markerEnd = "\u{00BB}"   // »

    /// Parses backend snippet markers into an attributed string with the matched
    /// runs emphasized in the accent colour.
    static func attributed(markedSnippet snippet: String, font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let normalFont = font
        let boldFont = UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        var remainder = Substring(snippet)
        while let start = remainder.range(of: markerStart) {
            let before = remainder[remainder.startIndex..<start.lowerBound]
            if !before.isEmpty {
                result.append(NSAttributedString(string: String(before), attributes: [.font: normalFont, .foregroundColor: UIColor.secondaryLabel]))
            }
            let afterStart = remainder[start.upperBound...]
            guard let end = afterStart.range(of: markerEnd) else {
                remainder = afterStart
                break
            }
            let highlighted = afterStart[afterStart.startIndex..<end.lowerBound]
            result.append(NSAttributedString(string: String(highlighted), attributes: [.font: boldFont, .foregroundColor: UIColor.systemOrange]))
            remainder = afterStart[end.upperBound...]
        }
        if !remainder.isEmpty {
            result.append(NSAttributedString(string: String(remainder), attributes: [.font: normalFont, .foregroundColor: UIColor.secondaryLabel]))
        }
        return result
    }

    /// Builds and highlights a snippet locally by finding the query within text,
    /// for results the backend didn't snippet (e.g. local cache hits).
    static func attributed(text: String, matching query: String, font: UIFont, window: Int = 80) -> NSAttributedString? {
        let foldedText = SearchIntelligence.fold(text)
        let foldedQuery = SearchIntelligence.fold(query)
        guard !foldedQuery.isEmpty, let range = foldedText.range(of: foldedQuery) else { return nil }
        // Map the folded offsets back onto the original string by distance.
        let lowerOffset = foldedText.distance(from: foldedText.startIndex, to: range.lowerBound)
        let upperOffset = foldedText.distance(from: foldedText.startIndex, to: range.upperBound)
        let origLower = text.index(text.startIndex, offsetBy: lowerOffset, limitedBy: text.endIndex) ?? text.startIndex
        let origUpper = text.index(text.startIndex, offsetBy: upperOffset, limitedBy: text.endIndex) ?? text.endIndex

        let start = text.index(origLower, offsetBy: -window, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(origUpper, offsetBy: window, limitedBy: text.endIndex) ?? text.endIndex
        let prefix = start > text.startIndex ? "… " : ""
        let suffix = end < text.endIndex ? " …" : ""

        let before = String(text[start..<origLower])
        let match = String(text[origLower..<origUpper])
        let after = String(text[origUpper..<end])

        let normalFont = font
        let boldFont = UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: prefix + before, attributes: [.font: normalFont, .foregroundColor: UIColor.secondaryLabel]))
        result.append(NSAttributedString(string: match, attributes: [.font: boldFont, .foregroundColor: UIColor.systemOrange]))
        result.append(NSAttributedString(string: after + suffix, attributes: [.font: normalFont, .foregroundColor: UIColor.secondaryLabel]))
        return result
    }
}
