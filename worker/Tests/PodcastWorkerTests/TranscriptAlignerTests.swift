@testable import PodcastWorker
import XCTest

// MARK: - Unit tests for offsetNear interpolation/extrapolation

final class OffsetNearTests: XCTestCase {
    private func chunk(index: Int, start: TimeInterval) -> AudioFingerprintChunk {
        AudioFingerprintChunk(index: index, start: start, duration: 5, hash: "h\(index)", profile: [128])
    }

    private func matches(_ pairs: [(backend: TimeInterval, local: TimeInterval)]) -> [(backend: AudioFingerprintChunk, local: AudioFingerprintChunk)] {
        pairs.enumerated().map { i, p in (chunk(index: i, start: p.backend), chunk(index: i + 1000, start: p.local)) }
    }

    func testReturnsNilWhenFewerThanThreeMatches() {
        let m = matches([(0, 30), (100, 130)])
        XCTAssertNil(TranscriptAligner.offsetNear(start: 50, matches: m, tolerance: 20))
    }

    func testExactMatchWithinTolerance() {
        let m = matches([(0, 30), (100, 130), (200, 230)])
        // Start=100 is exactly on a match with offset +30
        let offset = TranscriptAligner.offsetNear(start: 100, matches: m, tolerance: 20)
        XCTAssertEqual(offset ?? 0, 30, accuracy: 0.01)
    }

    func testInterpolatesBetweenTwoMatches() {
        // backend→local offset shifts from +30 at t=0 to +60 at t=200
        let m = matches([(0, 30), (100, 145), (200, 260)])  // at t=100 offset=45, at t=200 offset=60
        // Query at t=150 (between index 1 and 2): interpolate between (100,145) and (200,260)
        // lower offset = 145-100 = 45, upper offset = 260-200 = 60
        // t = (150-100)/(200-100) = 0.5, expected = 45 + 0.5*(60-45) = 52.5
        let offset = TranscriptAligner.offsetNear(start: 150, matches: m, tolerance: 10)
        XCTAssertEqual(offset ?? 0, 52.5, accuracy: 0.1)
    }

    func testExtrapolatesBeforeFirstMatch() {
        // All matches start at t=1200 (20 min in) — simulate DAI with front-loaded ads
        let m = matches([(1200, 1260), (1300, 1360), (1400, 1460)])
        // Segment at t=0 is before all matches; should extrapolate using first match offset (+60)
        let offset = TranscriptAligner.offsetNear(start: 0, matches: m, tolerance: 20)
        XCTAssertEqual(offset ?? 0, 60, accuracy: 0.1)
    }

    func testExtrapolatesAfterLastMatch() {
        // All matches end at t=2000 (33 min); episode continues to t=2700
        let m = matches([(1800, 1860), (1900, 1960), (2000, 2060)])
        // Segment at t=2700 is past all matches; should extrapolate using last match offset (+60)
        let offset = TranscriptAligner.offsetNear(start: 2700, matches: m, tolerance: 20)
        XCTAssertEqual(offset ?? 0, 60, accuracy: 0.1)
    }

    func testOldBehaviorWouldReturnNilForFarSegment() {
        // Demonstrate that the old tolerance-only check would return nil for this case.
        // The nearest match is 1200s away — far beyond the 20s tolerance.
        let m = matches([(1200, 1260), (1300, 1360), (1400, 1460)])
        let nearest = m.min(by: { abs($0.backend.start - 0) < abs($1.backend.start - 0) })!
        XCTAssertGreaterThan(abs(nearest.backend.start - 0), 20, "Nearest match IS far — old code returned nil here")
        // New code should NOT return nil
        XCTAssertNotNil(TranscriptAligner.offsetNear(start: 0, matches: m, tolerance: 20))
    }
}

// MARK: - Integration test with real backend data + downloaded MP3

final class TranscriptAlignerIntegrationTests: XCTestCase {
    private let mp3URL = URL(fileURLWithPath: "/Users/hannesnagel/Desktop/Podcasts/1cc14e74bc30cbc57d1a65457ebcea92e898dc7b9ed918e14a561c4f9e08d461.mp3")

    private var fixturesDir: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    }

    private func loadBackendFingerprint() throws -> AudioFingerprint {
        let data = try Data(contentsOf: fixturesDir.appendingPathComponent("ep194_fingerprint.json"))
        return try JSONDecoder().decode(AudioFingerprint.self, from: data)
    }

    private func loadBackendTranscript() throws -> (segmentsJSON: String, segmentFingerprintsJSON: String?) {
        struct TranscriptArtifact: Decodable {
            let segmentsJSON: String
            let segmentFingerprintsJSON: String?
        }
        let data = try Data(contentsOf: fixturesDir.appendingPathComponent("ep194_transcript.json"))
        let artifact = try JSONDecoder().decode(TranscriptArtifact.self, from: data)
        return (artifact.segmentsJSON, artifact.segmentFingerprintsJSON)
    }

    func testAlignerCoversMajorityOfEpisode() async throws {
        guard FileManager.default.fileExists(atPath: mp3URL.path) else {
            throw XCTSkip("Local MP3 not present at expected path")
        }

        let backendFingerprint = try loadBackendFingerprint()
        let (segmentsJSON, segmentFingerprintsJSON) = try loadBackendTranscript()

        print("Fingerprinting local MP3…")
        let localFingerprint = try await AudioFingerprintMaker.fingerprint(audioFile: mp3URL)
        print("Local chunks: \(try chunkCount(localFingerprint)), Backend chunks: \(try chunkCount(backendFingerprint))")

        let result = TranscriptAligner.align(
            transcriptSegmentsJSON: segmentsJSON,
            segmentFingerprintsJSON: segmentFingerprintsJSON,
            backendFingerprint: backendFingerprint,
            localFingerprint: localFingerprint
        )

        let r = try XCTUnwrap(result, "Aligner returned nil — no result at all")
        let pct = Double(r.matchedSegmentCount) / Double(r.totalSegmentCount) * 100
        print("Coverage: \(r.matchedSegmentCount)/\(r.totalSegmentCount) segments (\(String(format: "%.1f", pct))%)")
        print("Has unmatched (inserted audio): \(r.hasUnmatchedSegments)")

        // Decode the aligned segments to inspect time distribution
        let alignedSegs = try JSONDecoder().decode([AlignedSegmentDTO].self, from: Data(r.json.utf8))
        let contentSegs = alignedSegs.filter { $0.alignmentStatus == nil }
        let starts = contentSegs.compactMap(\.start).sorted()
        if let first = starts.first, let last = starts.last {
            print("Aligned time range: \(format(first)) – \(format(last))")

            // The old algorithm only covered 19:53–34:54 (~15 minutes).
            // With extrapolation, the span must cover most of the episode.
            let coveredSpan = last - first
            print("Covered span: \(format(coveredSpan))")
            XCTAssertGreaterThan(coveredSpan, 2000,
                "Aligned span should cover most of the episode (old bug gave ~15 min, episode is ~44 min)")
        }

        // At least 90% coverage overall
        XCTAssertGreaterThanOrEqual(pct, 90.0, "Expected ≥90% segment coverage, got \(String(format: "%.1f", pct))%")
    }

    func testAlignerReportsGlobalMatchDistribution() async throws {
        guard FileManager.default.fileExists(atPath: mp3URL.path) else {
            throw XCTSkip("Local MP3 not present at expected path")
        }

        let backendFingerprint = try loadBackendFingerprint()
        let backendChunks = try JSONDecoder().decode([AudioFingerprintChunk].self, from: Data(backendFingerprint.chunksJSON.utf8))
        let localFingerprint = try await AudioFingerprintMaker.fingerprint(audioFile: mp3URL)
        let localChunks = try JSONDecoder().decode([AudioFingerprintChunk].self, from: Data(localFingerprint.chunksJSON.utf8))
        let localByHash = Dictionary(grouping: localChunks, by: \.hash)

        let exactMatches = TranscriptAligner.uniqueMatches(backendChunks: backendChunks, localByHash: localByHash)
        let approxMatches = TranscriptAligner.approximateProfileMatches(backendChunks: backendChunks, localChunks: localChunks)
        print("Exact chunk matches: \(exactMatches.count)")
        print("Approximate chunk matches: \(approxMatches.count)")

        if !exactMatches.isEmpty {
            let backendStarts = exactMatches.map(\.backend.start).sorted()
            let localStarts = exactMatches.map(\.local.start).sorted()
            print("Backend match range: \(format(backendStarts.first!)) – \(format(backendStarts.last!))")
            print("Local match range:   \(format(localStarts.first!)) – \(format(localStarts.last!))")

            let offsets = exactMatches.map { $0.local.start - $0.backend.start }.sorted()
            print("Offset range: \(String(format: "%.1f", offsets.first!))s – \(String(format: "%.1f", offsets.last!))s")
        }

        // With the improved aligner, segments outside the matched range should
        // be assigned an extrapolated offset rather than dropped.
        XCTAssertGreaterThanOrEqual(exactMatches.count + approxMatches.count, 3,
            "Expected at least 3 chunk matches between backend and local files")
    }

    // MARK: - Helpers

    private func chunkCount(_ fp: AudioFingerprint) throws -> Int {
        try JSONDecoder().decode([AudioFingerprintChunk].self, from: Data(fp.chunksJSON.utf8)).count
    }

    private func format(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    private struct AlignedSegmentDTO: Decodable {
        let start: TimeInterval?
        let end: TimeInterval?
        let text: String
        let alignmentStatus: String?
    }
}
