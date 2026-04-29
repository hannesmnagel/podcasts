@testable import PodcastWorker
import XCTest

final class ChapterizerTests: XCTestCase {
    func testOllamaChapterizerMapsAnchorsToSegmentStartTimes() throws {
        let episode = EpisodeDTO(
            id: nil,
            podcastStableID: nil,
            stableID: "episode-1",
            title: "A Long Conversation",
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
}
