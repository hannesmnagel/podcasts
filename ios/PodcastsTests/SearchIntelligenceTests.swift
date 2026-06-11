import XCTest
@testable import Podcasts

/// Tests for the on-device search intelligence, including a regression test for
/// the EXC_BAD_ACCESS crash caused by concurrent NLEmbedding access.
final class SearchIntelligenceTests: XCTestCase {

    // MARK: - Normalization

    func testFoldNormalizesCaseAndDiacritics() {
        XCTAssertEqual(SearchIntelligence.fold("Pokémon"), "pokemon")
        XCTAssertEqual(SearchIntelligence.fold("  CLIMATE  "), "climate")
        XCTAssertEqual(SearchIntelligence.fold("Café"), "cafe")
    }

    func testLemmasDropStopWordsAndShortTokens() {
        let lemmas = SearchIntelligence.lemmas(of: "the running of races")
        XCTAssertFalse(lemmas.contains("the"))
        XCTAssertFalse(lemmas.contains("of"))
        XCTAssertFalse(lemmas.isEmpty)
    }

    func testLemmasOfEmptyStringIsEmpty() {
        XCTAssertTrue(SearchIntelligence.lemmas(of: "").isEmpty)
        XCTAssertTrue(SearchIntelligence.lemmas(of: "   ").isEmpty)
    }

    // MARK: - Similarity

    func testSimilarityReturnsZeroForEmptyOrWhitespaceInput() {
        XCTAssertEqual(SearchIntelligence.similarity(query: "", text: "climate"), 0)
        XCTAssertEqual(SearchIntelligence.similarity(query: "   ", text: "climate"), 0)
        XCTAssertEqual(SearchIntelligence.similarity(query: "climate", text: ""), 0)
        XCTAssertEqual(SearchIntelligence.similarity(query: "climate", text: "\n\t "), 0)
    }

    func testSimilarityIsBoundedBetweenZeroAndOne() {
        let pairs = [
            ("climate change", "global warming and the climate crisis"),
            ("interest rates", "the federal reserve raised interest rates"),
            ("zzzz", "completely unrelated content"),
        ]
        for (query, text) in pairs {
            let score = SearchIntelligence.similarity(query: query, text: text)
            XCTAssertGreaterThanOrEqual(score, 0, "similarity below 0 for \(query)")
            XCTAssertLessThanOrEqual(score, 1, "similarity above 1 for \(query)")
            XCTAssertTrue(score.isFinite, "similarity not finite for \(query)")
        }
    }

    func testExpandedTermsIncludeOriginalTerms() {
        let terms = SearchIntelligence.expandedTerms(for: "climate")
        XCTAssertTrue(terms.contains("climate"))
    }

    // MARK: - Concurrency regression

    /// NLEmbedding is not thread-safe; before serialization, concurrent
    /// `distance`/`neighbors` calls crashed with EXC_BAD_ACCESS. Hammering the
    /// API from many threads must now complete without crashing.
    func testConcurrentEmbeddingAccessDoesNotCrash() {
        let queries = ["climate", "interest rates", "vaccine policy", "ukraine",
                       "artificial intelligence", "", "  ", "Pokémon"]
        let texts = ["global warming explained in depth", "the federal reserve",
                     "public health update today", "geopolitics and conflict",
                     "machine learning research", "miscellaneous", "noise", "games"]

        DispatchQueue.concurrentPerform(iterations: 300) { iteration in
            let query = queries[iteration % queries.count]
            let text = texts[iteration % texts.count]
            _ = SearchIntelligence.similarity(query: query, text: text)
            if iteration % 3 == 0 {
                _ = SearchIntelligence.expandedTerms(for: query)
            }
        }
    }
}
