@testable import PodcastWorker
import XCTest

final class ChapterizerTests: XCTestCase {
    func testOllamaChapterizerMapsAnchorsToSegmentStartTimes() throws {
        let episode = EpisodeDTO(
            id: nil,
            podcastStableID: nil,
            stableID: "episode-1",
            title: "A Long Conversation",
            summary: nil,
            audioURL: "https://example.com/audio.mp3",
            duration: 1_800
        )
        let response = """
        {"chapters":[{"title":"Launch Plan","startAnchor":"talk about the launch plan","endAnchor":"what has changed"},{"title":"Too Close","startAnchor":"nearby duplicate chapter","endAnchor":"skip this"},{"title":"Performance","startAnchor":"performance and how the app behaves","endAnchor":"under load"}]}
        """
        let segments = [
            TranscriptSegment(start: 0, end: 30, text: "Welcome to a long conversation about software and product decisions."),
            TranscriptSegment(start: 300, end: 330, text: "Now we should talk about the launch plan and what has changed."),
            TranscriptSegment(start: 320, end: 340, text: "This is a nearby duplicate chapter that should be skipped."),
            TranscriptSegment(start: 900, end: 930, text: "Our next topic is performance and how the app behaves under load.")
        ]

        let chapters = try OllamaChapterizer(
            baseURL: URL(string: "http://localhost:11434")!,
            model: "llama3.1:8b",
            minimumSpacing: 180,
            maximumChapters: 8
        ).parseChapters(from: response, episode: episode, segments: segments)

        XCTAssertEqual(chapters.first?.start, 0)
        XCTAssertEqual(chapters.map(\.start), [0, 300, 900])
        XCTAssertEqual(chapters.last?.title, "Performance")
    }

    func testChapterizationTranscriptUsesFullWindowsAndRelativePauses() {
        var segments: [TranscriptSegment] = []
        var time: TimeInterval = 0
        for index in 0..<360 {
            if index == 30 { time += 12 }
            segments.append(TranscriptSegment(start: time, end: time + 0.5, text: "segment \(index) full transcript text"))
            time += 1
        }

        let transcript = OllamaChapterizer(
            baseURL: URL(string: "http://localhost:11434")!,
            model: "llama3.1:8b",
            minimumSpacing: 180,
            maximumChapters: 8
        ).chapterizationTranscript(from: segments)
        let lines = transcript.components(separatedBy: "\n")

        XCTAssertTrue(lines[0].hasPrefix("[0s-29s]"), lines.prefix(3).joined(separator: "\n"))
        XCTAssertTrue(lines[0].contains("segment 0 full transcript text"))
        XCTAssertTrue(lines[0].contains("segment 29 full transcript text"))
        XCTAssertTrue(lines[1].hasPrefix("[42s-"), lines.prefix(3).joined(separator: "\n"))
        XCTAssertTrue(lines[1].contains("segment 30 full transcript text"))
    }

    func testOllamaChapterizerAgainstTranscriptFixtureWhenEnabled() async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["PODCAST_CHAPTERIZER_FIXTURE"] else {
            throw XCTSkip("Set PODCAST_CHAPTERIZER_FIXTURE to run the Ollama integration chapterization test")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let artifact = try JSONDecoder().decode(TranscriptFixture.self, from: data)
        let segments = try JSONDecoder().decode([TranscriptSegment].self, from: Data(artifact.segmentsJSON.utf8))
        let episode = EpisodeDTO(
            id: nil,
            podcastStableID: artifact.podcastStableID,
            stableID: artifact.stableID ?? "fixture",
            title: artifact.title ?? "Transcript Fixture",
            summary: artifact.summary,
            audioURL: artifact.audioURL ?? "https://example.com/audio.mp3",
            duration: segments.compactMap(\.end).max()
        )

        let chapters = try await OllamaChapterizer(
            baseURL: URL(string: ProcessInfo.processInfo.environment["PODCAST_OLLAMA_URL"] ?? "http://localhost:11434")!,
            model: ProcessInfo.processInfo.environment["PODCAST_OLLAMA_MODEL"] ?? "gemma3:12b",
            minimumSpacing: 90,
            maximumChapters: 24,
            contextWindow: Int(ProcessInfo.processInfo.environment["PODCAST_OLLAMA_CONTEXT"] ?? "65536") ?? 65_536,
            logRawResponses: ProcessInfo.processInfo.environment["PODCAST_CHAPTER_LOG_RAW"] == "true"
        ).chapters(for: episode, segments: segments)

        for chapter in chapters {
            print("\(Int(chapter.start))s\t\(chapter.title)")
        }
        XCTAssertGreaterThanOrEqual(chapters.count, 6)
        XCTAssertEqual(chapters.first?.start, 0)
    }
}

private struct TranscriptFixture: Decodable {
    let segmentsJSON: String
    let stableID: String?
    let podcastStableID: String?
    let title: String?
    let summary: String?
    let audioURL: String?
}
