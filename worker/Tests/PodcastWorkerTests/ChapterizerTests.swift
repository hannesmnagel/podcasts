@testable import PodcastWorker
import XCTest

final class ChapterizerTests: XCTestCase {
    func testOllamaChapterizerParsesAndNormalizesJSON() throws {
        let episode = EpisodeDTO(
            id: nil,
            podcastStableID: nil,
            stableID: "episode-1",
            title: "A Long Conversation",
            audioURL: "https://example.com/audio.mp3",
            duration: 1_800
        )
        let response = """
        {"chapters":[{"start":300.8,"title":"Launch Plan"},{"start":320,"title":"Too Close"},{"start":900,"title":"Performance"}]}
        """

        let chapters = try OllamaChapterizer(
            baseURL: URL(string: "http://localhost:11434")!,
            model: "llama3.2:3b",
            minimumSpacing: 180,
            maximumChapters: 8
        ).parseChapters(from: response, episode: episode, duration: 1_800)

        XCTAssertEqual(chapters.first?.start, 0)
        XCTAssertEqual(chapters.map(\.start), [0, 300, 900])
        XCTAssertEqual(chapters.last?.title, "Performance")
    }
}
