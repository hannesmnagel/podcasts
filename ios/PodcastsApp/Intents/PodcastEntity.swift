import AppIntents
import Foundation
import PodcatcherKit

struct PodcastEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast")
    static let defaultQuery = PodcastEntityQuery()

    var id: String
    var title: String
    var artworkFileURL: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct PodcastEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PodcastEntity] {
        let snapshot = SharedStateReader.librarySnapshot()
        return (snapshot?.subscriptions ?? [])
            .filter { identifiers.contains($0.stableID) }
            .map { PodcastEntity(id: $0.stableID, title: $0.title, artworkFileURL: $0.artworkFileURL) }
    }

    func suggestedEntities() async throws -> [PodcastEntity] {
        let snapshot = SharedStateReader.librarySnapshot()
        return (snapshot?.subscriptions ?? []).map {
            PodcastEntity(id: $0.stableID, title: $0.title, artworkFileURL: $0.artworkFileURL)
        }
    }
}
