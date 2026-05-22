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
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.kind, "transcript")

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

    func testTranscriptOnlyRequestDoesNotQueueChapters() async throws {
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
            let response = try res.content.decode(ArtifactRequestResponse.self)
            XCTAssertEqual(response.transcriptCount, 1)
            XCTAssertEqual(response.chapterCount, 0)
        })

        let jobs = try await WorkerJob.query(on: app.db).all()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.kind, "transcript")

        let podcastDemand = try await PodcastDemand.query(on: app.db).filter(\.$podcast.$id == podcast.requireID()).first()
        XCTAssertEqual(podcastDemand?.transcriptRequests, 1)
        XCTAssertEqual(podcastDemand?.chapterRequests, 0)
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
        transcript.segmentFingerprintsJSON = "[]"
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

    func testCompletedChapterJobWithoutArtifactDoesNotCreateJobWithoutTranscript() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try await app.asyncShutdown() } }
        try await configure(app)
        try await app.autoMigrate()

        let podcast = Podcast(stableID: "podcast-stable", feedURL: "https://example.com/feed.xml", title: "Example")
        try await podcast.save(on: app.db)
        let episode = Episode(podcastID: try podcast.requireID(), stableID: "episode-stable", guid: "1", title: "Episode", audioURL: "https://example.com/audio.mp3")
        try await episode.save(on: app.db)

        let job = WorkerJob(episodeID: try episode.requireID(), kind: "chapters", priority: 10)
        job.status = "completed"
        job.completedAt = Date()
        try await job.save(on: app.db)

        try await app.test(.POST, "episodes/episode-stable/artifact-requests", beforeRequest: { req in
            try req.content.encode(ArtifactDemandRequest(transcript: false, chapters: true, fingerprint: false))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })

        let jobs = try await WorkerJob.query(on: app.db).filter(\.$kind == "chapters").all()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertTrue(jobs.contains { $0.status == "completed" })
    }

    func testOldTranscriptWithoutSegmentFingerprintsIsRequeued() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try await app.asyncShutdown() } }
        try await configure(app)
        try await app.autoMigrate()

        let podcast = Podcast(stableID: "podcast-stable", feedURL: "https://example.com/feed.xml", title: "Example")
        try await podcast.save(on: app.db)
        let episode = Episode(podcastID: try podcast.requireID(), stableID: "episode-stable", guid: "1", title: "Episode", audioURL: "https://example.com/audio.mp3")
        try await episode.save(on: app.db)

        let transcript = TranscriptArtifact()
        transcript.$episode.id = try episode.requireID()
        transcript.locale = "en"
        transcript.model = "test"
        transcript.segmentsJSON = "[]"
        transcript.segmentFingerprintsJSON = nil
        transcript.textHash = "hash"
        try await transcript.save(on: app.db)

        try await app.test(.POST, "episodes/episode-stable/artifact-requests", beforeRequest: { req in
            try req.content.encode(ArtifactDemandRequest(transcript: true, chapters: false, fingerprint: true))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })

        let jobs = try await WorkerJob.query(on: app.db).filter(\.$kind == "transcript").all()
        XCTAssertEqual(jobs.count, 1)
    }

    func testIdleWorkerSeedsBacklogFromMostPopularPodcastFirst() async throws {
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

        let lowDemand = PodcastDemand(podcastID: try lowPodcast.requireID())
        lowDemand.transcriptRequests = 1
        try await lowDemand.save(on: app.db)
        let hotDemand = PodcastDemand(podcastID: try hotPodcast.requireID())
        hotDemand.transcriptRequests = 5
        try await hotDemand.save(on: app.db)

        try await app.test(.POST, "worker/jobs/claim", beforeRequest: { req in
            try req.content.encode(ClaimJobRequest(workerID: "test-worker"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let job = try res.content.decode(ClaimedWorkerJobResponse.self)
            XCTAssertEqual(job.episode.stableID, "hot-episode")
        })
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

    func testQueueMonitorPageReflectsCurrentQueueState() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try await app.asyncShutdown() } }
        try await configure(app)
        try await app.autoMigrate()

        let podcast = Podcast(stableID: "podcast-stable", feedURL: "https://example.com/feed.xml", title: "Example Podcast")
        try await podcast.save(on: app.db)
        let episode = Episode(podcastID: try podcast.requireID(), stableID: "episode-stable", guid: "1", title: "Queue Episode", audioURL: "https://example.com/audio.mp3")
        try await episode.save(on: app.db)

        let pendingJob = WorkerJob(episodeID: try episode.requireID(), kind: "transcript", priority: 7)
        try await pendingJob.save(on: app.db)

        let transcript = TranscriptArtifact()
        transcript.$episode.id = try episode.requireID()
        transcript.locale = "en"
        transcript.model = "test"
        transcript.segmentsJSON = "[]"
        transcript.segmentFingerprintsJSON = "[]"
        transcript.textHash = "hash"
        try await transcript.save(on: app.db)

        let claimedJob = WorkerJob(episodeID: try episode.requireID(), kind: "chapters", priority: 3)
        claimedJob.status = "claimed"
        claimedJob.claimedBy = "test-worker"
        claimedJob.claimedAt = Date(timeIntervalSinceNow: -7_300)
        try await claimedJob.save(on: app.db)

        let controller = QueueMonitorController()
        let snapshot = try await controller.snapshot(on: app.db)
        XCTAssertEqual(snapshot.totalJobs, 2)
        XCTAssertEqual(snapshot.pendingJobs.count, 1)
        XCTAssertEqual(snapshot.claimedJobs.count, 1)
        XCTAssertEqual(snapshot.staleClaimedJobs.count, 1)

        let html = QueueMonitorController.renderHTML(snapshot: snapshot)
        XCTAssertTrue(html.contains("Queue Monitor"))
        XCTAssertTrue(html.contains("Pending Queue"))
        XCTAssertTrue(html.contains("Claimed Queue"))

        try await app.test(.GET, "queue", afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.contentType?.description, "text/html; charset=utf-8")
        })
    }

    func testPodcastIDIsStableForURLNormalization() {
        XCTAssertEqual(
            StableID.podcastID(feedURL: "HTTPS://EXAMPLE.COM/feed.xml#fragment"),
            StableID.podcastID(feedURL: "https://example.com/feed.xml")
        )
    }

    func testWorkerDoesNotClaimSecondTranscriptForSameWorker() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try await app.asyncShutdown() } }
        try await configure(app)
        try await app.autoMigrate()

        let podcast = Podcast(stableID: "podcast-stable", feedURL: "https://example.com/feed.xml", title: "Example")
        try await podcast.save(on: app.db)

        let firstEpisode = Episode(podcastID: try podcast.requireID(), stableID: "episode-1", guid: "1", title: "Episode 1", audioURL: "https://example.com/1.mp3")
        let secondEpisode = Episode(podcastID: try podcast.requireID(), stableID: "episode-2", guid: "2", title: "Episode 2", audioURL: "https://example.com/2.mp3")
        try await firstEpisode.save(on: app.db)
        try await secondEpisode.save(on: app.db)

        let firstJob = WorkerJob(episodeID: try firstEpisode.requireID(), kind: "transcript", priority: 100)
        let secondJob = WorkerJob(episodeID: try secondEpisode.requireID(), kind: "transcript", priority: 90)
        try await firstJob.save(on: app.db)
        try await secondJob.save(on: app.db)

        try await app.test(.POST, "worker/jobs/claim", beforeRequest: { req in
            try req.content.encode(ClaimJobRequest(workerID: "test-worker"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })

        try await app.test(.POST, "worker/jobs/claim", beforeRequest: { req in
            try req.content.encode(ClaimJobRequest(workerID: "test-worker"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .noContent)
        })
    }

    func testWorkerPriorityTiersPreferNewRequestedThenNewHotPodcastThenOldRequested() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try await app.asyncShutdown() } }
        try await configure(app)
        try await app.autoMigrate()

        let coldPodcast = Podcast(stableID: "cold-podcast", feedURL: "https://example.com/cold.xml", title: "Cold")
        let hotPodcast = Podcast(stableID: "hot-podcast", feedURL: "https://example.com/hot.xml", title: "Hot")
        try await coldPodcast.save(on: app.db)
        try await hotPodcast.save(on: app.db)

        let now = Date()
        let oldDate = Calendar.current.date(byAdding: .day, value: -120, to: now) ?? .distantPast
        let newDate = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now

        let newRequested = Episode(podcastID: try coldPodcast.requireID(), stableID: "new-requested", guid: "nr", title: "New Requested", audioURL: "https://example.com/nr.mp3", publishedAt: newDate)
        let newHotPodcast = Episode(podcastID: try hotPodcast.requireID(), stableID: "new-hot", guid: "nh", title: "New Hot", audioURL: "https://example.com/nh.mp3", publishedAt: newDate)
        let oldRequested = Episode(podcastID: try coldPodcast.requireID(), stableID: "old-requested", guid: "or", title: "Old Requested", audioURL: "https://example.com/or.mp3", publishedAt: oldDate)
        try await newRequested.save(on: app.db)
        try await newHotPodcast.save(on: app.db)
        try await oldRequested.save(on: app.db)

        let hotDemand = PodcastDemand(podcastID: try hotPodcast.requireID())
        hotDemand.transcriptRequests = 10
        try await hotDemand.save(on: app.db)

        let reqNew = ArtifactRequest(episodeID: try newRequested.requireID())
        reqNew.transcriptCount = 2
        try await reqNew.save(on: app.db)
        let reqOld = ArtifactRequest(episodeID: try oldRequested.requireID())
        reqOld.transcriptCount = 3
        try await reqOld.save(on: app.db)

        let j1 = WorkerJob(episodeID: try newRequested.requireID(), kind: "transcript", priority: 1)
        let j2 = WorkerJob(episodeID: try newHotPodcast.requireID(), kind: "transcript", priority: 1)
        let j3 = WorkerJob(episodeID: try oldRequested.requireID(), kind: "transcript", priority: 1)
        try await j1.save(on: app.db)
        try await j2.save(on: app.db)
        try await j3.save(on: app.db)

        try await app.test(.POST, "worker/jobs/claim", beforeRequest: { req in
            try req.content.encode(ClaimJobRequest(workerID: "worker-a"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let job = try res.content.decode(ClaimedWorkerJobResponse.self)
            XCTAssertEqual(job.episode.stableID, "new-requested")
        })

        j1.status = "completed"
        j1.completedAt = Date()
        try await j1.save(on: app.db)

        try await app.test(.POST, "worker/jobs/claim", beforeRequest: { req in
            try req.content.encode(ClaimJobRequest(workerID: "worker-b"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let job = try res.content.decode(ClaimedWorkerJobResponse.self)
            XCTAssertEqual(job.episode.stableID, "new-hot")
        })
    }

    func testStaleClaimDoesNotBlockTranscriptClaimForSameWorker() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try await app.asyncShutdown() } }
        try await configure(app)
        try await app.autoMigrate()

        let podcast = Podcast(stableID: "podcast-stale", feedURL: "https://example.com/stale.xml", title: "Stale")
        try await podcast.save(on: app.db)
        let staleEpisode = Episode(podcastID: try podcast.requireID(), stableID: "stale-episode", guid: "s1", title: "Stale Episode", audioURL: "https://example.com/s1.mp3")
        let freshEpisode = Episode(podcastID: try podcast.requireID(), stableID: "fresh-episode", guid: "f1", title: "Fresh Episode", audioURL: "https://example.com/f1.mp3")
        try await staleEpisode.save(on: app.db)
        try await freshEpisode.save(on: app.db)

        let staleClaimed = WorkerJob(episodeID: try staleEpisode.requireID(), kind: "transcript", priority: 100)
        staleClaimed.status = "claimed"
        staleClaimed.claimedBy = "test-worker"
        staleClaimed.claimedAt = Date(timeIntervalSinceNow: -7_300) // older than default 7200s timeout
        try await staleClaimed.save(on: app.db)

        let pending = WorkerJob(episodeID: try freshEpisode.requireID(), kind: "transcript", priority: 90)
        try await pending.save(on: app.db)

        try await app.test(.POST, "worker/jobs/claim", beforeRequest: { req in
            try req.content.encode(ClaimJobRequest(workerID: "test-worker"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let job = try res.content.decode(ClaimedWorkerJobResponse.self)
            XCTAssertEqual(job.episode.stableID, "fresh-episode")
        })
    }
}
