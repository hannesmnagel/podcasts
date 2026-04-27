import Vapor

func routes(_ app: Application) throws {
    app.get { _ in HealthResponse(status: "ok") }
    try app.register(collection: PodcastController())
    try app.register(collection: EpisodeController())
    try app.register(collection: ArtifactController())
    try app.register(collection: WorkerController())
}

struct HealthResponse: Content { let status: String }
