import AVFoundation
import Foundation

struct AudioFingerprintDTO: Codable, Hashable, Sendable {
    let id: UUID?
    let renditionID: String?
    let algorithm: String
    let chunkDuration: Double
    let chunksJSON: String
    let audioHash: String?
}

struct AudioFingerprintUpload: Codable, Hashable, Sendable {
    let renditionID: String?
    let algorithm: String
    let chunkDuration: Double
    let chunksJSON: String
    let audioHash: String?
}

struct AudioFingerprintChunk: Codable, Hashable, Sendable {
    let index: Int
    let start: TimeInterval
    let duration: TimeInterval
    let hash: String
    let profile: [UInt8]
}

enum AudioFingerprintMaker {
    static let algorithm = "podcatcher-rms-v1"
    static let sampleRate: Double = 8_000
    static let chunkDuration: TimeInterval = 5
    static let bucketsPerChunk = 10

    static func fingerprint(audioFile: URL) async throws -> AudioFingerprintUpload {
        let chunks = try makeChunks(audioFile: audioFile)
        let chunksJSON = String(decoding: try JSONEncoder().encode(chunks), as: UTF8.self)
        let audioHash = try? stableFileHash(audioFile)
        return AudioFingerprintUpload(renditionID: audioHash, algorithm: algorithm, chunkDuration: chunkDuration, chunksJSON: chunksJSON, audioHash: audioHash)
    }

    private static func makeChunks(audioFile: URL) throws -> [AudioFingerprintChunk] {
        let asset = AVURLAsset(url: audioFile)
        guard let track = asset.tracks(withMediaType: .audio).first else { return [] }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        reader.startReading()

        let bucketFrames = max(1, Int(sampleRate * chunkDuration / Double(bucketsPerChunk)))
        let chunkFrames = bucketFrames * bucketsPerChunk
        var bucketSquares = Array(repeating: Double(0), count: bucketsPerChunk)
        var bucketCounts = Array(repeating: 0, count: bucketsPerChunk)
        var frameIndex = 0
        var chunkIndex = 0
        var chunks: [AudioFingerprintChunk] = []

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { rawBuffer in
                if let base = rawBuffer.baseAddress {
                    _ = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
                }
            }
            data.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Float.self)
                for sample in samples {
                    let local = frameIndex % chunkFrames
                    let bucket = min(bucketsPerChunk - 1, local / bucketFrames)
                    let value = Double(sample)
                    bucketSquares[bucket] += value * value
                    bucketCounts[bucket] += 1
                    frameIndex += 1
                    if frameIndex % chunkFrames == 0 {
                        chunks.append(chunk(index: chunkIndex, bucketSquares: bucketSquares, bucketCounts: bucketCounts))
                        chunkIndex += 1
                        bucketSquares = Array(repeating: 0, count: bucketsPerChunk)
                        bucketCounts = Array(repeating: 0, count: bucketsPerChunk)
                    }
                }
            }
        }
        if bucketCounts.reduce(0, +) > Int(sampleRate) {
            chunks.append(chunk(index: chunkIndex, bucketSquares: bucketSquares, bucketCounts: bucketCounts))
        }
        return chunks
    }

    private static func chunk(index: Int, bucketSquares: [Double], bucketCounts: [Int]) -> AudioFingerprintChunk {
        let profile: [UInt8] = zip(bucketSquares, bucketCounts).map { squares, count in
            guard count > 0 else { return 0 }
            let rms = sqrt(squares / Double(count))
            let db = max(-80, min(0, 20 * log10(max(rms, 0.000_001))))
            return UInt8(max(0, min(255, Int(((db + 80) / 80) * 255))))
        }
        return AudioFingerprintChunk(index: index, start: Double(index) * chunkDuration, duration: chunkDuration, hash: stableHash(profile), profile: profile)
    }

    private static func stableHash(_ bytes: [UInt8]) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private static func stableFileHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash: UInt64 = 1469598103934665603
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 1024 * 1024)
            guard !data.isEmpty else { return false }
            for byte in data {
                hash ^= UInt64(byte)
                hash &*= 1099511628211
            }
            return true
        }) {}
        return String(hash, radix: 16)
    }
}

struct TranscriptSegmentFingerprintChunk: Codable, Hashable, Sendable {
    let start: TimeInterval
    let hash: String
}

struct TranscriptSegmentFingerprint: Codable, Hashable, Sendable {
    let index: Int
    let start: TimeInterval?
    let end: TimeInterval?
    let textHash: String
    let chunks: [TranscriptSegmentFingerprintChunk]
}

struct TranscriptAlignmentResult {
    let json: String
    let hasUnmatchedSegments: Bool
}

enum TranscriptAligner {
    static func alignedSegmentsJSON(transcriptSegmentsJSON: String, segmentFingerprintsJSON: String?, backendFingerprint: AudioFingerprintDTO, localFingerprint: AudioFingerprintUpload) -> TranscriptAlignmentResult? {
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

        if backendFingerprint.audioHash != nil, backendFingerprint.audioHash == localFingerprint.audioHash {
            return TranscriptAlignmentResult(json: transcriptSegmentsJSON, hasUnmatchedSegments: false)
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

        for (index, segment) in segments.enumerated() {
            guard let start = segment.start else { continue }
            let fallbackOffset = offsetNear(start: start, matches: globalMatches, tolerance: anchorTolerance)
            let segmentOffset = segmentFingerprints[index].flatMap {
                offset(for: $0, localByHash: localByHash, tolerance: backendFingerprint.chunkDuration, fallbackOffset: fallbackOffset)
            }
            guard let offset = segmentOffset ?? fallbackOffset else { continue }
            matchedCount += 1
            matched.append(AlignedTranscriptSegment(start: max(0, start + offset), end: segment.end.map { max(0, $0 + offset) }, text: segment.text, alignmentStatus: nil, originalStart: segment.start, originalEnd: segment.end))
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

        // Keep partial alignments instead of invalidating the whole transcript when
        // only some audio windows match the downloaded rendition.
        guard matchedCount >= max(1, min(3, segments.count / 10)) else { return nil }
        let json = String(decoding: (try? JSONEncoder().encode(aligned)) ?? Data(), as: UTF8.self)
        return TranscriptAlignmentResult(json: json, hasUnmatchedSegments: insertedAudioCount > 0)
    }

    private static func uniqueMatches(backendChunks: [AudioFingerprintChunk], localByHash: [String: [AudioFingerprintChunk]]) -> [(backend: AudioFingerprintChunk, local: AudioFingerprintChunk)] {
        backendChunks.compactMap { backendChunk in
            guard let candidates = localByHash[backendChunk.hash], candidates.count == 1 else { return nil }
            return (backendChunk, candidates[0])
        }
    }

    private static func approximateProfileMatches(backendChunks: [AudioFingerprintChunk], localChunks: [AudioFingerprintChunk]) -> [(backend: AudioFingerprintChunk, local: AudioFingerprintChunk)] {
        let windowSize = 3
        guard backendChunks.count >= windowSize, localChunks.count >= windowSize else { return [] }

        var localBestBackendIndex: [Int: Int] = [:]
        for localIndex in 0...(localChunks.count - windowSize) {
            guard let best = bestProfileWindowMatch(
                sourceStartIndex: localIndex,
                sourceChunks: localChunks,
                candidateChunks: backendChunks,
                windowSize: windowSize
            ) else { continue }
            localBestBackendIndex[localIndex] = best.index
        }

        var matches: [(backend: AudioFingerprintChunk, local: AudioFingerprintChunk)] = []
        var usedLocalIndexes = Set<Int>()
        for backendIndex in 0...(backendChunks.count - windowSize) {
            guard let best = bestProfileWindowMatch(
                sourceStartIndex: backendIndex,
                sourceChunks: backendChunks,
                candidateChunks: localChunks,
                windowSize: windowSize
            ),
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
            let distance = profileWindowDistance(
                sourceStartIndex: sourceStartIndex,
                candidateStartIndex: candidateIndex,
                sourceChunks: sourceChunks,
                candidateChunks: candidateChunks,
                windowSize: windowSize
            )
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

        guard let best,
              best.distance <= 18,
              secondBestDistance - best.distance >= 3 else { return nil }
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

    private static func offsetNear(start: TimeInterval, matches: [(backend: AudioFingerprintChunk, local: AudioFingerprintChunk)], tolerance: TimeInterval) -> TimeInterval? {
        guard matches.count >= 3,
              let match = matches.min(by: { abs($0.backend.start - start) < abs($1.backend.start - start) }),
              abs(match.backend.start - start) <= tolerance else {
            return nil
        }
        return match.local.start - match.backend.start
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
            if cluster.count > bestCluster.count {
                bestCluster = cluster
            }
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

private struct AlignedTranscriptSegment: Encodable {
    let start: TimeInterval?
    let end: TimeInterval?
    let text: String
    let alignmentStatus: String?
    let originalStart: TimeInterval?
    let originalEnd: TimeInterval?
}
