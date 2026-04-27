import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import Vapor

public func configure(_ app: Application) async throws {
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    app.http.server.configuration.hostname = Environment.get("HOSTNAME") ?? "127.0.0.1"
    if let port = Environment.get("PORT").flatMap(Int.init) { app.http.server.configuration.port = port }

    if app.environment == .testing {
        app.databases.use(.sqlite(.memory), as: .sqlite)
    } else {
        let hostname = Environment.get("DATABASE_HOSTNAME") ?? "localhost"
        let port = Environment.get("DATABASE_PORT").flatMap(Int.init) ?? SQLPostgresConfiguration.ianaPortNumber
        let username = Environment.get("DATABASE_USERNAME") ?? "podcasts"
        let password = Environment.get("DATABASE_PASSWORD") ?? "podcasts"
        let database = Environment.get("DATABASE_DATABASE") ?? "podcasts"
        app.databases.use(.postgres(configuration: .init(hostname: hostname, port: port, username: username, password: password, database: database)), as: .psql)
    }

    app.migrations.add(CreatePodcast())
    app.migrations.add(CreateEpisode())
    app.migrations.add(CreateArtifactRequest())
    app.migrations.add(CreatePodcastDemand())
    app.migrations.add(CreateTranscriptArtifact())
    app.migrations.add(CreateChapterArtifact())
    app.migrations.add(CreateWorkerJob())

    try routes(app)
}
