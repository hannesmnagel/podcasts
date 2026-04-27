import Foundation

struct WorkerConfig {
    var backendURL = URL(string: ProcessInfo.processInfo.environment["PODCAST_BACKEND_URL"] ?? "http://localhost:8080")!
    var workerID = ProcessInfo.processInfo.environment["PODCAST_WORKER_ID"] ?? Host.current().localizedName ?? UUID().uuidString
    var runOnce = ProcessInfo.processInfo.environment["PODCAST_WORKER_RUN_ONCE"] == "true"
    var idleSleepSeconds = UInt64(ProcessInfo.processInfo.environment["PODCAST_WORKER_IDLE_SECONDS"] ?? "60") ?? 60
    var allowStubTranscripts = ProcessInfo.processInfo.environment["PODCAST_WORKER_ALLOW_STUB"] == "true"
    var whisperCommand = ProcessInfo.processInfo.environment["PODCAST_WHISPER_COMMAND"] ?? "whisper"
}

@main
enum PodcastWorker {
    static func main() async throws {
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
        do {
            switch job.kind {
            case "transcript":
                let transcript = try await makeTranscript(for: job.episode)
                try await client.uploadTranscript(transcript, episodeID: job.episode.stableID)
            case "chapters":
                let chapters = try await makeChapters(for: job.episode)
                try await client.uploadChapters(chapters, episodeID: job.episode.stableID)
            default:
                throw WorkerError.unsupportedJobKind(job.kind)
            }
            _ = try await client.completeJob(job.id)
            print("completed job \(job.id)")
        } catch {
            try? await client.failJob(job.id)
            throw error
        }
    }

    private func makeTranscript(for episode: EpisodeDTO) async throws -> TranscriptUploadDTO {
        let audioFile = try await downloadAudio(from: episode.audioURL, stableID: episode.stableID)
        defer { try? FileManager.default.removeItem(at: audioFile) }

        if let whisper = try? await WhisperRunner(command: config.whisperCommand).transcribe(audioFile: audioFile) {
            return TranscriptUploadDTO(
                renditionID: nil,
                locale: whisper.language ?? "unknown",
                model: whisper.model,
                segmentsJSON: whisper.segmentsJSON,
                textHash: whisper.text.stableHash
            )
        }

        guard config.allowStubTranscripts else { throw WorkerError.whisperUnavailable }
        let segment = TranscriptSegment(start: 0, end: nil, text: "Transcript requested for \(episode.title). Local transcription is not configured yet.")
        let data = try JSONEncoder().encode([segment])
        let segmentsJSON = String(decoding: data, as: UTF8.self)
        return TranscriptUploadDTO(renditionID: nil, locale: "unknown", model: "stub", segmentsJSON: segmentsJSON, textHash: segmentsJSON.stableHash)
    }

    private func makeChapters(for episode: EpisodeDTO) async throws -> ChaptersUploadDTO {
        let chapters = [ChapterDTO(start: 0, title: episode.title)]
        let data = try JSONEncoder().encode(chapters)
        return ChaptersUploadDTO(source: "worker-basic", chaptersJSON: String(decoding: data, as: UTF8.self))
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

    func uploadChapters(_ upload: ChaptersUploadDTO, episodeID: String) async throws {
        let _: ChapterArtifactDTO = try await post("episodes/\(episodeID)/chapters", body: upload)
    }

    func completeJob(_ id: UUID) async throws -> WorkerJobDTO {
        try await post("worker/jobs/\(id.uuidString)/complete", body: EmptyBody())
    }

    func failJob(_ id: UUID) async throws {
        let _: WorkerJobDTO = try await post("worker/jobs/\(id.uuidString)/fail", body: EmptyBody())
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

    private func url(for path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 204 { throw WorkerError.noContent }
        guard (200..<300).contains(http.statusCode) else {
            throw WorkerError.server(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
    }
}

struct WhisperRunner {
    let command: String

    func transcribe(audioFile: URL) async throws -> WhisperResult {
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command, audioFile.path, "--output_format", "json", "--output_dir", outputDirectory.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw WorkerError.whisperFailed(process.terminationStatus) }

        guard let jsonFile = try FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "json" }) else {
            throw WorkerError.whisperOutputMissing
        }
        let data = try Data(contentsOf: jsonFile)
        let output = try JSONDecoder().decode(WhisperOutput.self, from: data)
        let segments = output.segments.map { TranscriptSegment(start: $0.start, end: $0.end, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let segmentsData = try JSONEncoder().encode(segments)
        return WhisperResult(language: output.language, model: command, text: output.text, segmentsJSON: String(decoding: segmentsData, as: UTF8.self))
    }
}

struct ClaimJobRequest: Codable { let workerID: String }
struct EmptyBody: Codable {}

struct WorkerJobDTO: Codable, Identifiable {
    let id: UUID
    let kind: String
    let priority: Int
    let episode: EpisodeDTO
}

struct EpisodeDTO: Codable, Identifiable {
    let id: UUID?
    let stableID: String
    let title: String
    let audioURL: String
    let duration: TimeInterval?
}

struct TranscriptUploadDTO: Codable {
    let renditionID: String?
    let locale: String
    let model: String
    let segmentsJSON: String
    let textHash: String
}

struct ChaptersUploadDTO: Codable {
    let source: String
    let chaptersJSON: String
}

struct TranscriptArtifactDTO: Codable { let id: UUID? }
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
}

enum WorkerError: LocalizedError {
    case noContent
    case server(status: Int, body: String?)
    case unsupportedJobKind(String)
    case downloadFailed(Int)
    case whisperUnavailable
    case whisperFailed(Int32)
    case whisperOutputMissing

    var errorDescription: String? {
        switch self {
        case .noContent: "No pending worker jobs"
        case let .server(status, body): "Backend error \(status): \(body ?? "")"
        case let .unsupportedJobKind(kind): "Unsupported job kind: \(kind)"
        case let .downloadFailed(status): "Audio download failed with HTTP \(status)"
        case .whisperUnavailable: "Whisper command is unavailable; set PODCAST_WHISPER_COMMAND or PODCAST_WORKER_ALLOW_STUB=true for development"
        case let .whisperFailed(status): "Whisper failed with exit code \(status)"
        case .whisperOutputMissing: "Whisper did not produce a JSON output file"
        }
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
