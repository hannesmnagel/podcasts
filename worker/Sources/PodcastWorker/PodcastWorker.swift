import Foundation

nonisolated(unsafe) private var activeChildProcess: Process?
nonisolated(unsafe) private var activeJobID: UUID?
nonisolated(unsafe) private var activeJobBackendURL: URL?

struct WorkerConfig {
    var backendURL = URL(string: ProcessInfo.processInfo.environment["PODCAST_BACKEND_URL"] ?? "http://localhost:8080")!
    var workerID = ProcessInfo.processInfo.environment["PODCAST_WORKER_ID"] ?? Host.current().localizedName ?? UUID().uuidString
    var runOnce = ProcessInfo.processInfo.environment["PODCAST_WORKER_RUN_ONCE"] == "true"
    var idleSleepSeconds = UInt64(ProcessInfo.processInfo.environment["PODCAST_WORKER_IDLE_SECONDS"] ?? "60") ?? 60
    var allowStubTranscripts = ProcessInfo.processInfo.environment["PODCAST_WORKER_ALLOW_STUB"] == "true"
    var whisperCommand = ProcessInfo.processInfo.environment["PODCAST_WHISPER_COMMAND"] ?? "whisper"
    var whisperModel = ProcessInfo.processInfo.environment["PODCAST_WHISPER_MODEL"] ?? ""
    var chapterProvider = ProcessInfo.processInfo.environment["PODCAST_CHAPTER_PROVIDER"] ?? "openrouter"
    var openRouterModel = ProcessInfo.processInfo.environment["PODCAST_OPENROUTER_MODEL"] ?? "tencent/hy3-preview"
    var openRouterContextWindow = Int(ProcessInfo.processInfo.environment["PODCAST_OPENROUTER_CONTEXT"] ?? "262144") ?? 262_144
    var openRouterMaxOutputTokens = Int(ProcessInfo.processInfo.environment["PODCAST_OPENROUTER_MAX_TOKENS"] ?? "2048") ?? 2_048
    var openRouterAPIKey = Self.openRouterAPIKey()
    var ollamaURL = URL(string: ProcessInfo.processInfo.environment["PODCAST_OLLAMA_URL"] ?? "http://localhost:11434")!
    var ollamaModel = ProcessInfo.processInfo.environment["PODCAST_OLLAMA_MODEL"] ?? "gemma3:12b"
    var ollamaContextWindow = Int(ProcessInfo.processInfo.environment["PODCAST_OLLAMA_CONTEXT"] ?? "65536") ?? 65_536
    var logRawOllamaResponses = ProcessInfo.processInfo.environment["PODCAST_CHAPTER_LOG_RAW"] == "true"
    var minimumChapterSpacing = TimeInterval(ProcessInfo.processInfo.environment["PODCAST_CHAPTER_MIN_SECONDS"] ?? "90") ?? 90
    var maximumChapters = Int(ProcessInfo.processInfo.environment["PODCAST_CHAPTER_MAX_COUNT"] ?? "24") ?? 24

    private static func openRouterAPIKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let key = env["PODCAST_OPENROUTER_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        if let keyPath = env["PODCAST_OPENROUTER_API_KEY_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines), !keyPath.isEmpty,
           let key = try? String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        return nil
    }
}

@main
enum PodcastWorker {
    static func main() async throws {
        var signalSources: [any DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler {
                activeChildProcess?.terminate()
                if let id = activeJobID, let base = activeJobBackendURL,
                   let url = URL(string: "worker/jobs/\(id.uuidString)/fail", relativeTo: base)?.absoluteURL {
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.addValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try? JSONEncoder().encode(FailJobRequest(retry: true))
                    let sem = DispatchSemaphore(value: 0)
                    URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
                    _ = sem.wait(timeout: .now() + 5)
                    print("\nfailed active job \(id) before exit")
                }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
        _ = signalSources  // keep alive for the duration of main

        let config = WorkerConfig()
        let client = WorkerBackendClient(baseURL: config.backendURL)
        let processor = JobProcessor(config: config, client: client)
        print("PodcastWorker starting: \(config.workerID) -> \(config.backendURL.absoluteString)")

        repeat {
            do {
                if let job = try await client.claimJob(workerID: config.workerID) {
                    print("claimed job \(job.id) [\(job.kind)] for \(job.episode.title)")
                    try await processor.process(job)
                } else {
                    print("no pending job; sleeping \(config.idleSleepSeconds)s")
                    try await Task.sleep(for: .seconds(config.idleSleepSeconds))
                }
            } catch {
                print("worker error: \(error.localizedDescription)")
                try await Task.sleep(for: .seconds(min(config.idleSleepSeconds, 30)))
            }
        } while !config.runOnce
    }
}

struct JobProcessor {
    let config: WorkerConfig
    let client: WorkerBackendClient

    func process(_ job: WorkerJobDTO) async throws {
        activeJobID = job.id
        activeJobBackendURL = client.baseURL
        defer {
            activeJobID = nil
            activeJobBackendURL = nil
        }
        do {
            switch job.kind {
            case "transcript":
                let transcript = try await makeTranscript(for: job.episode)
                try await client.uploadTranscript(transcript, episodeID: job.episode.stableID)
            case "chapters":
                if let chapters = try await makeChapters(for: job.episode) {
                    try await client.uploadChapters(chapters, episodeID: job.episode.stableID)
                }
            default:
                throw WorkerError.unsupportedJobKind(job.kind)
            }
            _ = try await client.completeJob(job.id)
            print("completed job \(job.id)")
        } catch {
            try? await client.failJob(job.id, retry: false)
            throw error
        }
    }

    private func makeTranscript(for episode: EpisodeDTO) async throws -> TranscriptUploadDTO {
        print("  downloading audio…")
        let audioFile = try await downloadAudio(from: episode.audioURL, stableID: episode.stableID)
        defer { try? FileManager.default.removeItem(at: audioFile) }
        let sizeMB = (try? audioFile.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .flatMap { Double($0) / 1_048_576 }
        let sizeStr = sizeMB.map { String(format: "%.1f MB", $0) } ?? "unknown size"
        print("  audio downloaded (\(sizeStr)), fingerprinting rendition…")
        let fingerprint = try? await AudioFingerprintMaker.fingerprint(audioFile: audioFile)
        if let fingerprint {
            let chunkCount = (try? JSONDecoder().decode([AudioFingerprintChunk].self, from: Data(fingerprint.chunksJSON.utf8)).count) ?? 0
            print("  fingerprint complete — \(chunkCount) chunks")
        } else {
            print("  fingerprint failed; continuing with transcript only")
        }
        print("  running Whisper…")

        if let whisper = try? await WhisperRunner(command: config.whisperCommand, model: config.whisperModel).transcribe(audioFile: audioFile, progressLabel: "transcript — \(episode.title)") {
            print("  transcription complete — language: \(whisper.language ?? "unknown"), \(whisper.segmentCount) segments")
            guard whisper.text.count >= 200 else { throw WorkerError.transcriptTooShort(whisper.text.count) }
            return TranscriptUploadDTO(
                renditionID: fingerprint?.renditionID,
                locale: whisper.language ?? "unknown",
                model: whisper.model,
                segmentsJSON: whisper.segmentsJSON,
                segmentFingerprintsJSON: SegmentFingerprintMaker.segmentFingerprintsJSON(transcriptSegmentsJSON: whisper.segmentsJSON, fingerprint: fingerprint),
                textHash: whisper.text.stableHash,
                fingerprint: fingerprint
            )
        }

        guard config.allowStubTranscripts else { throw WorkerError.whisperUnavailable }
        let segment = TranscriptSegment(start: 0, end: nil, text: "Transcript requested for \(episode.title). Local transcription is not configured yet.")
        let data = try JSONEncoder().encode([segment])
        let segmentsJSON = String(decoding: data, as: UTF8.self)
        return TranscriptUploadDTO(renditionID: fingerprint?.renditionID, locale: "unknown", model: "stub", segmentsJSON: segmentsJSON, segmentFingerprintsJSON: SegmentFingerprintMaker.segmentFingerprintsJSON(transcriptSegmentsJSON: segmentsJSON, fingerprint: fingerprint), textHash: segmentsJSON.stableHash, fingerprint: fingerprint)
    }

    private func makeChapters(for episode: EpisodeDTO) async throws -> ChaptersUploadDTO? {
        print("  loading transcript for chapterization…")
        let segments = try await transcriptSegments(for: episode)
        let source: String
        let chapters: [ChapterDTO]
        if config.chapterProvider.lowercased() == "openrouter" {
            guard let apiKey = config.openRouterAPIKey else { throw WorkerError.openRouterMissingAPIKey }
            chapters = try await OpenRouterChapterizer(
                apiKey: apiKey,
                model: config.openRouterModel,
                minimumSpacing: config.minimumChapterSpacing,
                maximumChapters: config.maximumChapters,
                contextWindow: config.openRouterContextWindow,
                maxOutputTokens: config.openRouterMaxOutputTokens
            ).chapters(for: episode, segments: segments)
            source = "worker-openrouter-\(config.openRouterModel)"
        } else {
            chapters = try await OllamaChapterizer(
                baseURL: config.ollamaURL,
                model: config.ollamaModel,
                minimumSpacing: config.minimumChapterSpacing,
                maximumChapters: config.maximumChapters,
                contextWindow: config.ollamaContextWindow,
                logRawResponses: config.logRawOllamaResponses
            ).chapters(for: episode, segments: segments)
            source = "worker-ollama-\(config.ollamaModel)"
        }
        guard chapters.count > 1 else { throw WorkerError.chapterizationFailed }
        print("  chapterization complete — \(chapters.count) chapters")
        let data = try JSONEncoder().encode(chapters)
        return ChaptersUploadDTO(source: source, chaptersJSON: String(decoding: data, as: UTF8.self))
    }

    private func transcriptSegments(for episode: EpisodeDTO) async throws -> [TranscriptSegment] {
        if let artifact = try await client.transcript(episodeID: episode.stableID),
           let segments = try decodeTranscriptSegments(artifact.segmentsJSON),
           !segments.isEmpty {
            print("  using stored transcript")
            return segments
        }

        print("  no stored transcript found; running Whisper for chapterization…")
        let upload = try await makeTranscript(for: episode)
        try await client.uploadTranscript(upload, episodeID: episode.stableID)
        guard let segments = try decodeTranscriptSegments(upload.segmentsJSON), !segments.isEmpty else {
            throw WorkerError.transcriptSegmentsMissing
        }
        return segments
    }

    private func decodeTranscriptSegments(_ segmentsJSON: String) throws -> [TranscriptSegment]? {
        guard let data = segmentsJSON.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode([TranscriptSegment].self, from: data)
    }

    private func downloadAudio(from rawURL: String, stableID: String) async throws -> URL {
        guard let url = URL(string: rawURL) else { throw URLError(.badURL) }
        let (source, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WorkerError.downloadFailed(http.statusCode)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("podcast-\(stableID)-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension.isEmpty ? "mp3" : url.pathExtension)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }
}

struct WorkerBackendClient {
    let baseURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(baseURL: URL) {
        self.baseURL = baseURL
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    func claimJob(workerID: String) async throws -> WorkerJobDTO? {
        do {
            return try await post("worker/jobs/claim", body: ClaimJobRequest(workerID: workerID))
        } catch WorkerError.noContent {
            return nil
        }
    }

    func uploadTranscript(_ upload: TranscriptUploadDTO, episodeID: String) async throws {
        let _: TranscriptArtifactDTO = try await post("episodes/\(episodeID)/transcript", body: upload)
    }

    func transcript(episodeID: String) async throws -> TranscriptArtifactDTO? {
        do {
            return try await get("episodes/\(episodeID)/transcript")
        } catch WorkerError.notFound {
            return nil
        }
    }

    func uploadChapters(_ upload: ChaptersUploadDTO, episodeID: String) async throws {
        let _: ChapterArtifactDTO = try await post("episodes/\(episodeID)/chapters", body: upload)
    }

    func completeJob(_ id: UUID) async throws -> WorkerJobDTO {
        try await post("worker/jobs/\(id.uuidString)/complete", body: EmptyBody())
    }

    func failJob(_ id: UUID, retry: Bool) async throws {
        let _: WorkerJobDTO = try await post("worker/jobs/\(id.uuidString)/fail", body: FailJobRequest(retry: retry))
    }

    private func post<Response: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> Response {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(from: url(for: path))
        try validate(response, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private func url(for path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 204 { throw WorkerError.noContent }
        if http.statusCode == 404 { throw WorkerError.notFound }
        guard (200..<300).contains(http.statusCode) else {
            throw WorkerError.server(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
    }
}

struct WhisperRunner {
    let command: String
    let model: String

    func transcribe(audioFile: URL, progressLabel: String) async throws -> WhisperResult {
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = [command, audioFile.path, "--output-format", "json", "--output-dir", outputDirectory.path]
        if !model.isEmpty { args += ["--model", model] }
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let progress = WhisperProgressLogger(label: progressLabel)
        @Sendable func streamLines(_ handle: FileHandle) {
            guard let text = String(data: handle.availableData, encoding: .utf8) else { return }
            progress.consume(text)
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = streamLines
        stderrPipe.fileHandleForReading.readabilityHandler = streamLines
        activeChildProcess = process
        try process.run()
        process.waitUntilExit()
        activeChildProcess = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        progress.finish()
        guard process.terminationStatus == 0 else { throw WorkerError.whisperFailed(process.terminationStatus) }

        guard let jsonFile = try FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "json" }) else {
            throw WorkerError.whisperOutputMissing
        }
        let data = try Data(contentsOf: jsonFile)
        let output = try JSONDecoder().decode(WhisperOutput.self, from: data)
        let segments = output.segments
            .map { TranscriptSegment(start: $0.start, end: $0.end, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { ($0.start ?? 0) < ($0.end ?? .infinity) }  // drop zero-duration segments
            .deduplicated(maxConsecutiveIdentical: 2)             // drop hallucination loops
        let segmentsData = try JSONEncoder().encode(segments)
        return WhisperResult(language: output.language, model: command, text: output.text, segmentsJSON: String(decoding: segmentsData, as: UTF8.self), segmentCount: segments.count)
    }
}

final class WhisperProgressLogger: @unchecked Sendable {
    private let lock = NSLock()
    private let label: String
    private var transcriptLineCount = 0
    private var printedProgress = false
    private var buffered = ""

    init(label: String) {
        self.label = label
    }

    func consume(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        buffered += text
        let lines = buffered.components(separatedBy: "\n")
        buffered = lines.last ?? ""
        for line in lines.dropLast() {
            consumeCompleteLine(line)
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        if !buffered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            consumeCompleteLine(buffered)
        }
        buffered = ""
        if printedProgress {
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private func consumeCompleteLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isTranscriptSegmentLine(trimmed) {
            transcriptLineCount += 1
            if transcriptLineCount == 1 || transcriptLineCount.isMultiple(of: 25) {
                updateProgress("  [\(label)] Whisper: ~\(transcriptLineCount) segments transcribed")
            }
            return
        }
        if trimmed.localizedCaseInsensitiveContains("progress") || trimmed.contains("%") {
            updateProgress("  [\(label)] \(trimmed)")
            return
        }
        if printedProgress {
            FileHandle.standardOutput.write(Data("\n".utf8))
            printedProgress = false
        }
        print("  \(trimmed)")
    }

    private func isTranscriptSegmentLine(_ line: String) -> Bool {
        line.hasPrefix("[") && line.contains(" --> ") && line.contains("]")
    }

    private func updateProgress(_ message: String) {
        printedProgress = true
        FileHandle.standardOutput.write(Data("\r\(message)".utf8))
    }
}

enum EmbeddedChapterLoader {
    private static let maximumTagBytes = 4 * 1024 * 1024

    static func chapters(from rawURL: String) async throws -> [ChapterDTO] {
        guard let url = URL(string: rawURL) else { throw URLError(.badURL) }
        let data: Data
        if url.isFileURL {
            data = try readID3TagFromFile(url)
        } else {
            data = try await readID3TagFromRemote(url)
        }
        return ID3ChapterParser.chapters(from: data)
    }

    private static func readID3TagFromFile(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 10) ?? Data()
        guard let tagLength = ID3ChapterParser.tagLength(fromHeader: header) else { return header }
        try handle.seek(toOffset: 0)
        return try handle.read(upToCount: min(maximumTagBytes, tagLength)) ?? Data()
    }

    private static func readID3TagFromRemote(_ url: URL) async throws -> Data {
        let header = try await rangedData(from: url, end: 9)
        guard let tagLength = ID3ChapterParser.tagLength(fromHeader: header) else { return header }
        return try await rangedData(from: url, end: min(maximumTagBytes, tagLength) - 1)
    }

    private static func rangedData(from url: URL, end: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.addValue("bytes=0-\(end)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
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
              data[data.startIndex + 2] == 0x33 else { return nil }
        let size = synchsafeInteger(data, at: data.startIndex + 6)
        return size > 0 ? size + 10 : nil
    }

    static func chapters(from data: Data) -> [ChapterDTO] {
        guard data.count >= 10,
              data[data.startIndex] == 0x49,
              data[data.startIndex + 1] == 0x44,
              data[data.startIndex + 2] == 0x33 else { return [] }

        let version = data[data.startIndex + 3]
        let flags = data[data.startIndex + 5]
        let tagSize = synchsafeInteger(data, at: data.startIndex + 6)
        let tagEnd = min(data.count, data.startIndex + 10 + tagSize)
        var offset = data.startIndex + 10

        if flags & 0x40 != 0, offset + 4 <= tagEnd {
            let extendedSize = version == 4 ? synchsafeInteger(data, at: offset) : bigEndianInteger(data, at: offset)
            offset += max(0, min(extendedSize + (version == 3 ? 4 : 0), tagEnd - offset))
        }

        var chapters: [ChapterDTO] = []
        while offset + 10 <= tagEnd {
            guard let frame = frameHeader(in: data, at: offset, version: version), frame.size > 0 else { break }
            let bodyStart = offset + 10
            let bodyEnd = min(tagEnd, bodyStart + frame.size)
            if frame.id == "CHAP", let chapter = chapterFrame(in: data, range: bodyStart..<bodyEnd, version: version) {
                chapters.append(chapter)
            }
            offset = bodyEnd
        }
        return chapters.sorted { $0.start < $1.start }.deduplicatedChapterStarts()
    }

    private static func chapterFrame(in data: Data, range: Range<Int>, version: UInt8) -> ChapterDTO? {
        guard range.lowerBound < range.upperBound, let idEnd = data[range].firstIndex(of: 0) else { return nil }
        let timingStart = idEnd + 1
        guard timingStart + 16 <= range.upperBound else { return nil }
        let startMilliseconds = bigEndianInteger(data, at: timingStart)
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
        return ChapterDTO(start: TimeInterval(startMilliseconds) / 1000, title: title)
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
        guard idData.allSatisfy({ byte in byte == 0 || (byte >= 0x30 && byte <= 0x5A) }), idData.contains(where: { $0 != 0 }) else { return nil }
        let id = String(decoding: idData, as: UTF8.self)
        let size = version == 4 ? synchsafeInteger(data, at: offset + 4) : bigEndianInteger(data, at: offset + 4)
        return (id, size)
    }

    private static func synchsafeInteger(_ data: Data, at offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        return (Int(data[offset]) << 21) | (Int(data[offset + 1]) << 14) | (Int(data[offset + 2]) << 7) | Int(data[offset + 3])
    }

    private static func bigEndianInteger(_ data: Data, at offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        return (Int(data[offset]) << 24) | (Int(data[offset + 1]) << 16) | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
    }
}

private extension Array where Element == ChapterDTO {
    func deduplicatedChapterStarts() -> [ChapterDTO] {
        var starts: Set<Int> = []
        return filter { chapter in starts.insert(Int(chapter.start.rounded())).inserted }
    }
}

struct ClaimJobRequest: Codable { let workerID: String }
struct FailJobRequest: Codable { let retry: Bool }
struct EmptyBody: Codable {}

struct WorkerJobDTO: Codable, Identifiable {
    let id: UUID
    let kind: String
    let priority: Int
    let episode: EpisodeDTO
}

struct EpisodeDTO: Codable, Identifiable {
    let id: UUID?
    let podcastStableID: String?
    let stableID: String
    let title: String
    let summary: String?
    let audioURL: String
    let duration: TimeInterval?
}

struct TranscriptUploadDTO: Codable {
    let renditionID: String?
    let locale: String
    let model: String
    let segmentsJSON: String
    let segmentFingerprintsJSON: String?
    let textHash: String
    let fingerprint: AudioFingerprint?
}

struct ChaptersUploadDTO: Codable {
    let source: String
    let chaptersJSON: String
}

struct TranscriptArtifactDTO: Codable {
    let id: UUID?
    let segmentsJSON: String
    let segmentFingerprintsJSON: String?
}
struct ChapterArtifactDTO: Codable { let id: UUID? }

struct TranscriptSegment: Codable {
    let start: TimeInterval?
    let end: TimeInterval?
    let text: String
}

struct ChapterDTO: Codable {
    let start: TimeInterval
    let title: String
}

struct WhisperOutput: Decodable {
    let text: String
    let language: String?
    let segments: [WhisperSegment]
}

struct WhisperSegment: Decodable {
    let start: TimeInterval?
    let end: TimeInterval?
    let text: String
}

struct WhisperResult {
    let language: String?
    let model: String
    let text: String
    let segmentsJSON: String
    let segmentCount: Int
}

enum WorkerError: LocalizedError {
    case noContent
    case notFound
    case server(status: Int, body: String?)
    case unsupportedJobKind(String)
    case downloadFailed(Int)
    case whisperUnavailable
    case whisperFailed(Int32)
    case whisperOutputMissing
    case transcriptTooShort(Int)
    case transcriptSegmentsMissing
    case chapterizationDisabled
    case chapterizationFailed
    case ollamaInvalidResponse(String)
    case openRouterMissingAPIKey
    case openRouterFailed(String)

    var errorDescription: String? {
        switch self {
        case .noContent: "No pending worker jobs"
        case .notFound: "Requested backend resource was not found"
        case let .server(status, body): "Backend error \(status): \(body ?? "")"
        case let .unsupportedJobKind(kind): "Unsupported job kind: \(kind)"
        case let .downloadFailed(status): "Audio download failed with HTTP \(status)"
        case .whisperUnavailable: "Whisper command is unavailable; set PODCAST_WHISPER_COMMAND or PODCAST_WORKER_ALLOW_STUB=true for development"
        case let .whisperFailed(status): "Whisper failed with exit code \(status)"
        case .whisperOutputMissing: "Whisper did not produce a JSON output file"
        case let .transcriptTooShort(count): "Transcript too short (\(count) chars) — likely a transcription failure"
        case .transcriptSegmentsMissing: "Transcript did not contain decodable timed segments"
        case .chapterizationDisabled: "Chapterization is disabled in the worker"
        case .chapterizationFailed: "Chapterization did not produce enough chapter boundaries"
        case let .ollamaInvalidResponse(reason): "Ollama did not return valid chapter JSON: \(reason)"
        case .openRouterMissingAPIKey: "OpenRouter API key missing; set PODCAST_OPENROUTER_API_KEY or PODCAST_OPENROUTER_API_KEY_FILE"
        case let .openRouterFailed(reason): "OpenRouter chapterization failed: \(reason)"
        }
    }
}

extension Array where Element == TranscriptSegment {
    func deduplicated(maxConsecutiveIdentical limit: Int) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var run = 0
        var lastText = ""
        for seg in self {
            if seg.text == lastText { run += 1 } else { run = 1; lastText = seg.text }
            if run <= limit { result.append(seg) }
        }
        return result
    }
}

extension String {
    var stableHash: String {
        var hash: UInt64 = 1469598103934665603
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

}
