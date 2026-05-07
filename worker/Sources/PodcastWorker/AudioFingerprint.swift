import AVFoundation
import Foundation

struct AudioFingerprint: Codable {
    let renditionID: String?
    let algorithm: String
    let chunkDuration: Double
    let chunksJSON: String
    let audioHash: String?
}

struct AudioFingerprintChunk: Codable, Hashable {
    let index: Int
    let start: TimeInterval
    let duration: TimeInterval
    let hash: String
    let profile: [UInt8]
}

struct TranscriptSegmentFingerprintChunk: Codable, Hashable {
    let start: TimeInterval
    let hash: String
}

struct TranscriptSegmentFingerprint: Codable, Hashable {
    let index: Int
    let start: TimeInterval?
    let end: TimeInterval?
    let textHash: String
    let chunks: [TranscriptSegmentFingerprintChunk]
}

enum SegmentFingerprintMaker {
    static func segmentFingerprintsJSON(transcriptSegmentsJSON: String, fingerprint: AudioFingerprint?) -> String? {
        guard let fingerprint,
              let segmentData = transcriptSegmentsJSON.data(using: .utf8),
              let chunkData = fingerprint.chunksJSON.data(using: .utf8),
              let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: segmentData),
              let chunks = try? JSONDecoder().decode([AudioFingerprintChunk].self, from: chunkData),
              !segments.isEmpty, !chunks.isEmpty else {
            return nil
        }
        let segmentFingerprints = segments.enumerated().map { index, segment in
            let segmentChunks = fingerprintChunks(for: segment, chunks: chunks, chunkDuration: fingerprint.chunkDuration)
            return TranscriptSegmentFingerprint(index: index, start: segment.start, end: segment.end, textHash: segment.text.stableHash, chunks: segmentChunks)
        }
        guard let data = try? JSONEncoder().encode(segmentFingerprints) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func fingerprintChunks(for segment: TranscriptSegment, chunks: [AudioFingerprintChunk], chunkDuration: TimeInterval) -> [TranscriptSegmentFingerprintChunk] {
        guard let start = segment.start else { return [] }
        let end = max(segment.end ?? (start + chunkDuration), start + 0.25)
        return chunks
            .filter { chunk in
                let chunkEnd = chunk.start + chunk.duration
                return chunk.start < end && chunkEnd > start
            }
            .map { TranscriptSegmentFingerprintChunk(start: $0.start, hash: $0.hash) }
    }
}

enum AudioFingerprintMaker {
    static let algorithm = "podcatcher-rms-v1"
    static let sampleRate: Double = 8_000
    static let chunkDuration: TimeInterval = 5
    static let bucketsPerChunk = 10

    static func fingerprint(audioFile: URL) async throws -> AudioFingerprint {
        let chunks = try makeChunks(audioFile: audioFile)
        let data = try JSONEncoder().encode(chunks)
        let chunksJSON = String(decoding: data, as: UTF8.self)
        let audioHash = try? stableFileHash(audioFile)
        return AudioFingerprint(
            renditionID: audioHash,
            algorithm: algorithm,
            chunkDuration: chunkDuration,
            chunksJSON: chunksJSON,
            audioHash: audioHash
        )
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
        return AudioFingerprintChunk(
            index: index,
            start: Double(index) * chunkDuration,
            duration: chunkDuration,
            hash: stableHash(profile),
            profile: profile
        )
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
