import Foundation

struct WorkerConfig {
    var backendURL = URL(string: ProcessInfo.processInfo.environment["PODCAST_BACKEND_URL"] ?? "http://localhost:8080")!
    var workerID = Host.current().localizedName ?? UUID().uuidString
}

@main
enum PodcastWorker {
    static func main() async throws {
        let config = WorkerConfig()
        print("PodcastWorker starting: \(config.workerID) -> \(config.backendURL.absoluteString)")
        print("Next: claim jobs, download audio, run local Whisper/SpeechAnalyzer-compatible transcription, upload transcript/chapter artifacts.")
    }
}
