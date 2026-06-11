import Foundation
import SwiftData

@Model
final class LocalEpisodeArtifact {
    var episodeStableID: String = ""
    var transcriptSegmentsJSON: String?
    var transcriptText: String?
    var transcriptLocale: String?
    var transcriptModel: String?
    var transcriptTextHash: String?
    var transcriptRenditionID: String?
    var transcriptSegmentFingerprintsJSON: String?
    var alignedTranscriptSegmentsJSON: String?
    var alignmentSourceAudioHash: String?
    var alignmentHasUnmatchedSegments: Bool?
    var alignmentAlgorithmVersion: String?
    var fingerprintAlgorithm: String?
    var fingerprintChunksJSON: String?
    var fingerprintAudioHash: String?
    var chaptersJSON: String?
    var chaptersSource: String?
    var chapterImageFilesJSON: Data?
    var updatedAt: Date = Date()

    init(episodeStableID: String) {
        self.episodeStableID = episodeStableID
        self.alignmentHasUnmatchedSegments = false
        self.updatedAt = .now
    }
}
