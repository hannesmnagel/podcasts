@testable import App
import XCTVapor
import Fluent

final class BackendTests: XCTestCase {
    func testCreatePodcastAndDemandSignal() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try await app.asyncShutdown() } }
        try await configure(app)
        try await app.autoMigrate()

        let podcast = Podcast(stableID: "podcast-stable", feedURL: "https://example.com/feed.xml", title: "Example")
        try await podcast.save(on: app.db)
        let episode = Episode(podcastID: try podcast.requireID(), stableID: "episode-stable", guid: "1", title: "Episode", audioURL: "https://example.com/audio.mp3")
        try await episode.save(on: app.db)

        try await app.test(.POST, "episodes/episode-stable/artifact-requests", beforeRequest: { req in
            try req.content.encode(ArtifactDemandRequest(transcript: true, chapters: true, fingerprint: false))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let response = try res.content.decode(ArtifactRequestResponse.self)
            XCTAssertEqual(response.transcriptCount, 1)
            XCTAssertEqual(response.chapterCount, 1)
        })

        let jobs = try await WorkerJob.query(on: app.db).all()
        XCTAssertEqual(jobs.count, 2)
        XCTAssertTrue(jobs.contains { $0.kind == "transcript" })
        XCTAssertTrue(jobs.contains { $0.kind == "chapters" })

        let podcastDemand = try await PodcastDemand.query(on: app.db).filter(\.$podcast.$id == podcast.requireID()).first()
        XCTAssertEqual(podcastDemand?.transcriptRequests, 1)
        XCTAssertEqual(podcastDemand?.chapterRequests, 1)
    }

    func testWorkerPrefersPodcastsWithMoreTranscriptDemand() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try await app.asyncShutdown() } }
        try await configure(app)
        try await app.autoMigrate()

        let lowPodcast = Podcast(stableID: "low-podcast", feedURL: "https://example.com/low.xml", title: "Low")
        let hotPodcast = Podcast(stableID: "hot-podcast", feedURL: "https://example.com/hot.xml", title: "Hot")
        try await lowPodcast.save(on: app.db)
        try await hotPodcast.save(on: app.db)

        let lowEpisode = Episode(podcastID: try lowPodcast.requireID(), stableID: "low-episode", guid: "low", title: "Low Episode", audioURL: "https://example.com/low.mp3")
        let hotEpisode = Episode(podcastID: try hotPodcast.requireID(), stableID: "hot-episode", guid: "hot", title: "Hot Episode", audioURL: "https://example.com/hot.mp3")
        try await lowEpisode.save(on: app.db)
        try await hotEpisode.save(on: app.db)

        try await app.test(.POST, "episodes/low-episode/artifact-requests", beforeRequest: { req in
            try req.content.encode(ArtifactDemandRequest(transcript: true, chapters: false, fingerprint: false))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })
        for _ in 0..<3 {
            try await app.test(.POST, "episodes/hot-episode/artifact-requests", beforeRequest: { req in
                try req.content.encode(ArtifactDemandRequest(transcript: true, chapters: false, fingerprint: false))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            })
        }

        try await app.test(.POST, "worker/jobs/claim", beforeRequest: { req in
            try req.content.encode(ClaimJobRequest(workerID: "test-worker"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let job = try res.content.decode(ClaimedWorkerJobResponse.self)
            XCTAssertEqual(job.episode.id, try hotEpisode.requireID())
            XCTAssertEqual(job.episode.stableID, "hot-episode")
        })
    }

    func testCompletedArtifactRequestDoesNotCreateDuplicateWorkerJob() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try await app.asyncShutdown() } }
        try await configure(app)
        try await app.autoMigrate()

        let podcast = Podcast(stableID: "podcast-stable", feedURL: "https://example.com/feed.xml", title: "Example")
        try await podcast.save(on: app.db)
        let episode = Episode(podcastID: try podcast.requireID(), stableID: "episode-stable", guid: "1", title: "Episode", audioURL: "https://example.com/audio.mp3")
        try await episode.save(on: app.db)

        try await app.test(.POST, "episodes/episode-stable/artifact-requests", beforeRequest: { req in
            try req.content.encode(ArtifactDemandRequest(transcript: true, chapters: false, fingerprint: false))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })

        guard let job = try await WorkerJob.query(on: app.db).filter(\.$kind == "transcript").first() else {
            return XCTFail("Expected transcript job")
        }
        job.status = "completed"
        job.completedAt = Date()
        try await job.save(on: app.db)

        let transcript = TranscriptArtifact()
        transcript.$episode.id = try episode.requireID()
        transcript.locale = "en"
        transcript.model = "test"
        transcript.segmentsJSON = "[]"
        transcript.textHash = "hash"
        try await transcript.save(on: app.db)

        try await app.test(.POST, "episodes/episode-stable/artifact-requests", beforeRequest: { req in
            try req.content.encode(ArtifactDemandRequest(transcript: true, chapters: false, fingerprint: false))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })

        let jobs = try await WorkerJob.query(on: app.db).filter(\.$kind == "transcript").all()
        XCTAssertEqual(jobs.count, 1)
    }

    func testFailedWorkerJobIsNotImmediatelyRequeued() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try await app.asyncShutdown() } }
        try await configure(app)
        try await app.autoMigrate()

        let podcast = Podcast(stableID: "podcast-stable", feedURL: "https://example.com/feed.xml", title: "Example")
        try await podcast.save(on: app.db)
        let episode = Episode(podcastID: try podcast.requireID(), stableID: "episode-stable", guid: "1", title: "Episode", audioURL: "https://example.com/audio.mp3")
        try await episode.save(on: app.db)
        let job = WorkerJob(episodeID: try episode.requireID(), kind: "transcript", priority: 10)
        try await job.save(on: app.db)

        try await app.test(.POST, "worker/jobs/claim", beforeRequest: { req in
            try req.content.encode(ClaimJobRequest(workerID: "test-worker"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })

        try await app.test(.POST, "worker/jobs/\(try job.requireID())/fail", beforeRequest: { req in
            try req.content.encode(FailJobRequest(retry: false))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })

        guard let failedJob = try await WorkerJob.find(try job.requireID(), on: app.db) else {
            return XCTFail("Expected failed job")
        }
        XCTAssertEqual(failedJob.status, "failed")

        try await app.test(.POST, "worker/jobs/claim", beforeRequest: { req in
            try req.content.encode(ClaimJobRequest(workerID: "test-worker"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .noContent)
        })
    }

    func testPodcastIDIsStableForURLNormalization() {
        XCTAssertEqual(
            StableID.podcastID(feedURL: "HTTPS://EXAMPLE.COM/feed.xml#fragment"),
            StableID.podcastID(feedURL: "https://example.com/feed.xml")
        )
    }
}
