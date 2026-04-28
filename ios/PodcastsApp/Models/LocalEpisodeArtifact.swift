import Foundation
import SwiftData

@Model
final class LocalEpisodeArtifact {
    @Attribute(.unique) var episodeStableID: String
    var transcriptSegmentsJSON: String?
    var transcriptText: String?
    var transcriptLocale: String?
    var transcriptModel: String?
    var transcriptTextHash: String?
    var chaptersJSON: String?
    var chaptersSource: String?
    var chapterImageFilesJSON: Data?
    var updatedAt: Date

    init(episodeStableID: String) {
        self.episodeStableID = episodeStableID
        self.updatedAt = .now
    }
}
