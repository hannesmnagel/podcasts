import Foundation
import SwiftData

@MainActor
enum LibraryStore {
    static func subscribe(to podcast: PodcastDTO, in context: ModelContext) {
        let stableID = podcast.stableID
        let descriptor = FetchDescriptor<PodcastSubscription>(predicate: #Predicate { $0.stableID == stableID })
        if let existing = try? context.fetch(descriptor).first {
            existing.title = podcast.title.isEmpty ? existing.title : podcast.title
            existing.artworkURL = podcast.imageURL.flatMap(URL.init(string:)) ?? existing.artworkURL
            existing.feedURL = URL(string: podcast.feedURL) ?? existing.feedURL
            return
        }
        guard let feedURL = URL(string: podcast.feedURL) else { return }
        let subscription = PodcastSubscription(
            stableID: stableID,
            feedURL: feedURL,
            title: podcast.title.isEmpty ? podcast.feedURL : podcast.title,
            artworkURL: podcast.imageURL.flatMap(URL.init(string:))
        )
        context.insert(subscription)
    }
}
