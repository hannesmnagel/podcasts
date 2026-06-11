import Foundation

struct TranscriptAlignmentResult {
    let json: String
    let hasUnmatchedSegments: Bool
    let matchedSegmentCount: Int
    let totalSegmentCount: Int
}

struct AlignedTranscriptSegment: Encodable {
    let start: TimeInterval?
    let end: TimeInterval?
    let text: String
    let alignmentStatus: String?
    let originalStart: TimeInterval?
    let originalEnd: TimeInterval?
}

enum TranscriptAligner {
    static let algorithmVersion = "2"

    // backend/local both use AudioFingerprint; audioHash equality is a fast-path shortcut.
    static func align(
        transcriptSegmentsJSON: String,
        segmentFingerprintsJSON: String?,
        backendFingerprint: AudioFingerprint,
        localFingerprint: AudioFingerprint
    ) -> TranscriptAlignmentResult? {
        guard backendFingerprint.algorithm == AudioFingerprintMaker.algorithm,
              backendFingerprint.algorithm == localFingerprint.algorithm,
              let transcriptData = transcriptSegmentsJSON.data(using: .utf8),
              let backendData = backendFingerprint.chunksJSON.data(using: .utf8),
              let localData = localFingerprint.chunksJSON.data(using: .utf8),
              let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: transcriptData),
              let backendChunks = try? JSONDecoder().decode([AudioFingerprintChunk].self, from: backendData),
              let localChunks = try? JSONDecoder().decode([AudioFingerprintChunk].self, from: localData),
              !segments.isEmpty, !backendChunks.isEmpty, !localChunks.isEmpty else {
            return nil
        }

        // Identical file — no offset needed.
        if backendFingerprint.audioHash != nil, backendFingerprint.audioHash == localFingerprint.audioHash {
            let total = segments.filter { $0.start != nil }.count
            return TranscriptAlignmentResult(json: transcriptSegmentsJSON, hasUnmatchedSegments: false, matchedSegmentCount: total, totalSegmentCount: total)
        }

        let localByHash = Dictionary(grouping: localChunks, by: \.hash)
        let globalMatches = mergedMatches(
            exactMatches: uniqueMatches(backendChunks: backendChunks, localByHash: localByHash),
            approximateMatches: approximateProfileMatches(backendChunks: backendChunks, localChunks: localChunks)
        )
        let segmentFingerprints = decodeSegmentFingerprints(segmentFingerprintsJSON)
        let anchorTolerance = max(20, backendFingerprint.chunkDuration * 4)
        var matched: [AlignedTranscriptSegment] = []
        var matchedCount = 0
        let timedSegments = segments.filter { $0.start != nil }

        for (index, segment) in segments.enumerated() {
            guard let start = segment.start else { continue }
            let fallbackOffset = offsetNear(start: start, matches: globalMatches, tolerance: anchorTolerance)
            let segmentOffset = segmentFingerprints[index].flatMap {
                offset(for: $0, localByHash: localByHash, tolerance: backendFingerprint.chunkDuration, fallbackOffset: fallbackOffset)
            }
            guard let offset = segmentOffset ?? fallbackOffset else { continue }
            matchedCount += 1
            matched.append(AlignedTranscriptSegment(
                start: max(0, start + offset),
                end: segment.end.map { max(0, $0 + offset) },
                text: segment.text,
                alignmentStatus: nil,
                originalStart: segment.start,
                originalEnd: segment.end
            ))
        }

        var aligned: [AlignedTranscriptSegment] = []
        var insertedAudioCount = 0
        let insertedAudioThreshold = max(8, backendFingerprint.chunkDuration * 2)
        for segment in matched {
            if let previous = aligned.last(where: { $0.alignmentStatus == nil }),
               let previousEnd = previous.end,
               let currentStart = segment.start {
                let localGap = currentStart - previousEnd
                let transcriptGap = max(0, (segment.originalStart ?? currentStart) - (previous.originalEnd ?? previousEnd))
                let insertedAudioDuration = localGap - transcriptGap
                if insertedAudioDuration >= insertedAudioThreshold {
                    insertedAudioCount += 1
                    aligned.append(AlignedTranscriptSegment(
                        start: previousEnd,
                        end: currentStart,
                        text: "Inserted audio not present in transcript",
                        alignmentStatus: "insertedAudio",
                        originalStart: previous.originalEnd,
                        originalEnd: segment.originalStart
                    ))
                }
            }
            aligned.append(segment)
        }

        guard matchedCount >= max(1, min(3, timedSegments.count / 10)) else { return nil }
        let json = String(decoding: (try? JSONEncoder().encode(aligned)) ?? Data(), as: UTF8.self)
        return TranscriptAlignmentResult(
            json: json,
            hasUnmatchedSegments: insertedAudioCount > 0,
            matchedSegmentCount: matchedCount,
            totalSegmentCount: timedSegments.count
        )
    }

    // MARK: - Internal helpers (internal for testing)

    static func offsetNear(start: TimeInterval, matches: [(backend: AudioFingerprintChunk, local: AudioFingerprintChunk)], tolerance: TimeInterval) -> TimeInterval? {
        guard matches.count >= 3 else { return nil }
        let sorted = matches.sorted { $0.backend.start < $1.backend.start }

        // Fast path: high-confidence match within tolerance window.
        let nearest = sorted.min(by: { abs($0.backend.start - start) < abs($1.backend.start - start) })!
        if abs(nearest.backend.start - start) <= tolerance {
            return nearest.local.start - nearest.backend.start
        }

        // Interpolate between surrounding matches, or extrapolate from boundary.
        // This handles DAI episodes where matched chunks only cover part of the timeline.
        let lower = sorted.last(where: { $0.backend.start <= start })
        let upper = sorted.first(where: { $0.backend.start > start })
        switch (lower, upper) {
        case let (l?, u?):
            let span = u.backend.start - l.backend.start
            guard span > 0 else { return l.local.start - l.backend.start }
            let t = (start - l.backend.start) / span
            let lo = l.local.start - l.backend.start
            let hi = u.local.start - u.backend.start
            return lo + t * (hi - lo)
        case let (l?, nil):
            return l.local.start - l.backend.start
        case let (nil, u?):
            return u.local.start - u.backend.start
        default:
            return nil
        }
    }

    static func uniqueMatches(backendChunks: [AudioFingerprintChunk], localByHash: [String: [AudioFingerprintChunk]]) -> [(backend: AudioFingerprintChunk, local: AudioFingerprintChunk)] {
        backendChunks.compactMap { backendChunk in
            guard let candidates = localByHash[backendChunk.hash], candidates.count == 1 else { return nil }
            return (backendChunk, candidates[0])
        }
    }

    static func approximateProfileMatches(backendChunks: [AudioFingerprintChunk], localChunks: [AudioFingerprintChunk]) -> [(backend: AudioFingerprintChunk, local: AudioFingerprintChunk)] {
        let windowSize = 3
        guard backendChunks.count >= windowSize, localChunks.count >= windowSize else { return [] }

        var localBestBackendIndex: [Int: Int] = [:]
        for localIndex in 0...(localChunks.count - windowSize) {
            guard let best = bestProfileWindowMatch(sourceStartIndex: localIndex, sourceChunks: localChunks, candidateChunks: backendChunks, windowSize: windowSize) else { continue }
            localBestBackendIndex[localIndex] = best.index
        }

        var matches: [(backend: AudioFingerprintChunk, local: AudioFingerprintChunk)] = []
        var usedLocalIndexes = Set<Int>()
        for backendIndex in 0...(backendChunks.count - windowSize) {
            guard let best = bestProfileWindowMatch(sourceStartIndex: backendIndex, sourceChunks: backendChunks, candidateChunks: localChunks, windowSize: windowSize),
                  localBestBackendIndex[best.index] == backendIndex,
                  usedLocalIndexes.insert(best.index).inserted else { continue }
            matches.append((backendChunks[backendIndex], localChunks[best.index]))
        }
        return matches
    }

    private static func bestProfileWindowMatch(sourceStartIndex: Int, sourceChunks: [AudioFingerprintChunk], candidateChunks: [AudioFingerprintChunk], windowSize: Int) -> (index: Int, distance: Double)? {
        var best: (index: Int, distance: Double)?
        var secondBestDistance = Double.greatestFiniteMagnitude
        for candidateIndex in 0...(candidateChunks.count - windowSize) {
            let distance = profileWindowDistance(sourceStartIndex: sourceStartIndex, candidateStartIndex: candidateIndex, sourceChunks: sourceChunks, candidateChunks: candidateChunks, windowSize: windowSize)
            if let currentBest = best {
                if distance < currentBest.distance {
                    secondBestDistance = currentBest.distance
                    best = (candidateIndex, distance)
                } else if distance < secondBestDistance {
                    secondBestDistance = distance
                }
            } else {
                best = (candidateIndex, distance)
            }
        }
        guard let best, best.distance <= 18, secondBestDistance - best.distance >= 3 else { return nil }
        return best
    }

    private static func profileWindowDistance(sourceStartIndex: Int, candidateStartIndex: Int, sourceChunks: [AudioFingerprintChunk], candidateChunks: [AudioFingerprintChunk], windowSize: Int) -> Double {
        var total = 0.0
        var count = 0
        for offset in 0..<windowSize {
            let sourceProfile = sourceChunks[sourceStartIndex + offset].profile
            let candidateProfile = candidateChunks[candidateStartIndex + offset].profile
            let pairCount = min(sourceProfile.count, candidateProfile.count)
            for index in 0..<pairCount {
                total += abs(Double(sourceProfile[index]) - Double(candidateProfile[index]))
                count += 1
            }
        }
        guard count > 0 else { return Double.greatestFiniteMagnitude }
        return total / Double(count)
    }

    private static func mergedMatches(exactMatches: [(backend: AudioFingerprintChunk, local: AudioFingerprintChunk)], approximateMatches: [(backend: AudioFingerprintChunk, local: AudioFingerprintChunk)]) -> [(backend: AudioFingerprintChunk, local: AudioFingerprintChunk)] {
        var byBackendIndex = Dictionary(uniqueKeysWithValues: exactMatches.map { ($0.backend.index, $0) })
        for match in approximateMatches where byBackendIndex[match.backend.index] == nil {
            byBackendIndex[match.backend.index] = match
        }
        return byBackendIndex.values.sorted { $0.backend.start < $1.backend.start }
    }

    private static func offset(for segment: TranscriptSegmentFingerprint, localByHash: [String: [AudioFingerprintChunk]], tolerance: TimeInterval, fallbackOffset: TimeInterval?) -> TimeInterval? {
        guard segment.start != nil else { return nil }
        let offsets = segment.chunks.compactMap { chunk -> TimeInterval? in
            guard let candidates = localByHash[chunk.hash], candidates.count == 1 else { return nil }
            return candidates[0].start - chunk.start
        }.sorted()
        guard !offsets.isEmpty else { return nil }

        if let fallbackOffset, offsets.count == 1, abs(offsets[0] - fallbackOffset) <= tolerance {
            return offsets[0]
        }

        var bestCluster: [TimeInterval] = []
        for offset in offsets {
            let cluster = offsets.filter { abs($0 - offset) <= tolerance }
            if cluster.count > bestCluster.count { bestCluster = cluster }
        }
        guard bestCluster.count >= 2 else { return nil }
        return bestCluster.sorted()[bestCluster.count / 2]
    }

    private static func decodeSegmentFingerprints(_ json: String?) -> [Int: TranscriptSegmentFingerprint] {
        guard let data = json?.data(using: .utf8),
              let fingerprints = try? JSONDecoder().decode([TranscriptSegmentFingerprint].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: fingerprints.map { ($0.index, $0) })
    }
}
