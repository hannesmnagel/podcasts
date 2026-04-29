import Foundation

enum ArtifactDataProcessor {
    @concurrent
    static func renderTranscript(segmentsJSON: String) async -> String {
        if let data = segmentsJSON.data(using: .utf8),
           let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: data) {
            return segments.map(\.text).joined(separator: "\n")
        }
        return segmentsJSON
    }

    @concurrent
    static func renderChapters(chaptersJSON: String) async -> [EpisodeChapterDTO] {
        guard let data = chaptersJSON.data(using: .utf8),
              let chapters = try? JSONDecoder().decode([EpisodeChapterDTO].self, from: data) else {
            return []
        }
        return chapters
    }
}

enum EmbeddedChapterLoader {
    private static let maximumTagBytes = 4 * 1024 * 1024

    @concurrent
    static func chapters(from url: URL) async -> [EpisodeChapterDTO] {
        do {
            let data: Data
            if url.isFileURL {
                data = try readID3TagFromFile(url)
            } else {
                data = try await readID3TagFromRemote(url)
            }
            return ID3ChapterParser.chapters(from: data)
        } catch {
            return []
        }
    }

    private static func readID3TagFromFile(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 10) ?? Data()
        guard let tagLength = ID3ChapterParser.tagLength(fromHeader: header) else { return header }
        try handle.seek(toOffset: 0)
        return try handle.read(upToCount: min(maximumTagBytes, tagLength)) ?? Data()
    }

    @concurrent
    private static func readID3TagFromRemote(_ url: URL) async throws -> Data {
        let header = try await rangedData(from: url, end: 9)
        guard let tagLength = ID3ChapterParser.tagLength(fromHeader: header) else { return header }
        return try await rangedData(from: url, end: min(maximumTagBytes, tagLength) - 1)
    }

    private static func rangedData(from url: URL, end: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.addValue("bytes=0-\(end)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        data.reserveCapacity(end + 1)
        for try await byte in bytes {
            data.append(byte)
            if data.count >= end + 1 { break }
        }
        return data
    }
}

enum ID3ChapterParser {
    static func tagLength(fromHeader data: Data) -> Int? {
        guard data.count >= 10,
              data[data.startIndex] == 0x49,
              data[data.startIndex + 1] == 0x44,
              data[data.startIndex + 2] == 0x33 else {
            return nil
        }
        let size = synchsafeInteger(data, at: data.startIndex + 6)
        return size > 0 ? size + 10 : nil
    }

    static func chapters(from data: Data) -> [EpisodeChapterDTO] {
        guard data.count >= 10,
              data[data.startIndex] == 0x49,
              data[data.startIndex + 1] == 0x44,
              data[data.startIndex + 2] == 0x33 else {
            return []
        }

        let version = data[data.startIndex + 3]
        let flags = data[data.startIndex + 5]
        let tagSize = synchsafeInteger(data, at: data.startIndex + 6)
        let tagEnd = min(data.count, data.startIndex + 10 + tagSize)
        var offset = data.startIndex + 10

        if flags & 0x40 != 0, offset + 4 <= tagEnd {
            let extendedSize = version == 4 ? synchsafeInteger(data, at: offset) : bigEndianInteger(data, at: offset)
            offset += max(0, min(extendedSize + (version == 3 ? 4 : 0), tagEnd - offset))
        }

        var chapters: [EpisodeChapterDTO] = []
        while offset + 10 <= tagEnd {
            guard let frame = frameHeader(in: data, at: offset, version: version), frame.size > 0 else { break }
            let bodyStart = offset + 10
            let bodyEnd = min(tagEnd, bodyStart + frame.size)
            if frame.id == "CHAP",
               let chapter = chapterFrame(in: data, range: bodyStart..<bodyEnd, version: version) {
                chapters.append(chapter)
            }
            offset = bodyEnd
        }

        return chapters
            .sorted { $0.start < $1.start }
            .deduplicatedByStart()
    }

    private static func chapterFrame(in data: Data, range: Range<Int>, version: UInt8) -> EpisodeChapterDTO? {
        guard range.lowerBound < range.upperBound,
              let idEnd = data[range].firstIndex(of: 0) else {
            return nil
        }
        let timingStart = idEnd + 1
        guard timingStart + 16 <= range.upperBound else { return nil }
        let startMilliseconds = bigEndianInteger(data, at: timingStart)
        let endMilliseconds = bigEndianInteger(data, at: timingStart + 4)
        var title: String?
        var offset = timingStart + 16

        while offset + 10 <= range.upperBound {
            guard let subframe = frameHeader(in: data, at: offset, version: version), subframe.size > 0 else { break }
            let bodyStart = offset + 10
            let bodyEnd = min(range.upperBound, bodyStart + subframe.size)
            if subframe.id == "TIT2" {
                title = textFrame(in: data, range: bodyStart..<bodyEnd)
                break
            }
            offset = bodyEnd
        }

        guard let title, !title.isEmpty else { return nil }
        let end = endMilliseconds > startMilliseconds ? TimeInterval(endMilliseconds) / 1000 : nil
        return EpisodeChapterDTO(start: TimeInterval(startMilliseconds) / 1000, end: end, title: title, imageURL: nil, artworkURL: nil)
    }

    private static func textFrame(in data: Data, range: Range<Int>) -> String? {
        guard range.lowerBound < range.upperBound else { return nil }
        let encoding = data[range.lowerBound]
        let textData = data[(range.lowerBound + 1)..<range.upperBound]
        let stringEncoding: String.Encoding = switch encoding {
        case 0: .isoLatin1
        case 1: .utf16
        case 2: .utf16BigEndian
        case 3: .utf8
        default: .utf8
        }
        return String(data: Data(textData), encoding: stringEncoding)?
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func frameHeader(in data: Data, at offset: Int, version: UInt8) -> (id: String, size: Int)? {
        guard offset + 10 <= data.count else { return nil }
        let idData = data[offset..<(offset + 4)]
        guard idData.allSatisfy({ byte in byte == 0 || (byte >= 0x30 && byte <= 0x5A) }) else { return nil }
        guard idData.contains(where: { $0 != 0 }) else { return nil }
        let id = String(decoding: idData, as: UTF8.self)
        let size = version == 4 ? synchsafeInteger(data, at: offset + 4) : bigEndianInteger(data, at: offset + 4)
        return (id, size)
    }

    private static func synchsafeInteger(_ data: Data, at offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        return (Int(data[offset]) << 21)
            | (Int(data[offset + 1]) << 14)
            | (Int(data[offset + 2]) << 7)
            | Int(data[offset + 3])
    }

    private static func bigEndianInteger(_ data: Data, at offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        return (Int(data[offset]) << 24)
            | (Int(data[offset + 1]) << 16)
            | (Int(data[offset + 2]) << 8)
            | Int(data[offset + 3])
    }
}

private extension Array where Element == EpisodeChapterDTO {
    func deduplicatedByStart() -> [EpisodeChapterDTO] {
        var starts: Set<Int> = []
        return filter { chapter in
            starts.insert(Int(chapter.start.rounded())).inserted
        }
    }
}
