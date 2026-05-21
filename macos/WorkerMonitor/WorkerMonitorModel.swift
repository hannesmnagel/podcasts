import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class WorkerMonitorModel {
    var repositoryPath = "/Users/hannesnagel/Desktop/Podcasts"
    var isRunning = false
    var workerPID = "unknown"
    var whisperPID = "none"
    var logTail = ""
    var currentJob = "No active job detected."
    var lastUpdatedText = "never"
    var errorMessage = ""
    var showsError = false

    let sessionName = "podcast-worker"

    private var timer: Timer?

    func startPolling() {
        stopPolling()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        isRunning = shell(["/opt/homebrew/bin/tmux", "has-session", "-t", sessionName]).exitCode == 0
        workerPID = readWorkerPID()
        whisperPID = readWhisperPID()
        logTail = readLogTail()
        currentJob = parseCurrentJob(from: logTail)
        lastUpdatedText = Self.timeFormatter.string(from: Date())
    }

    func startWorker() {
        let workerDirectory = "\(repositoryPath)/worker"
        let logPath = "\(workerDirectory)/logs/worker-current.log"
        let maxLines = 240
        let rotateSeconds = 5
        let command = """
        cd \(workerDirectory.shellQuoted) && \
        touch \(logPath.shellQuoted) && \
        tail -n \(maxLines) \(logPath.shellQuoted) > \(logPath.shellQuoted).tmp 2>/dev/null || true && \
        mv \(logPath.shellQuoted).tmp \(logPath.shellQuoted) 2>/dev/null || true && \
        (
          while true; do
            sleep \(rotateSeconds)
            tail -n \(maxLines) \(logPath.shellQuoted) > \(logPath.shellQuoted).tmp 2>/dev/null || true
            mv \(logPath.shellQuoted).tmp \(logPath.shellQuoted) 2>/dev/null || true
          done
        ) & \
        log_roller_pid=$! && \
        trap 'kill $log_roller_pid 2>/dev/null || true' EXIT INT TERM && \
        ./run.sh 2>&1 | tee -a \(logPath.shellQuoted)
        """
        let result = shell(["/opt/homebrew/bin/tmux", "new-session", "-d", "-s", sessionName, command])
        handle(result)
        refresh()
    }

    func stopWorker() {
        let result = shell(["/opt/homebrew/bin/tmux", "send-keys", "-t", sessionName, "C-c"])
        handle(result)
        refresh()
    }

    func openLogFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "\(repositoryPath)/worker/logs", isDirectory: true))
    }

    private func readWorkerPID() -> String {
        let pidPath = "\(repositoryPath)/worker/logs/worker.pid"
        guard let pid = try? String(contentsOfFile: pidPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !pid.isEmpty else {
            return "unknown"
        }
        return pid
    }

    private func readWhisperPID() -> String {
        let result = shell(["/bin/ps", "axo", "pid=,command="])
        guard result.exitCode == 0 else { return "unknown" }
        let matches = result.output
            .split(separator: "\n")
            .filter { $0.contains("mlx_whisper") || $0.contains("whisper") }
            .filter { !$0.contains("WorkerMonitor") }
        guard let first = matches.first else { return "none" }
        return first.split(separator: " ").first.map(String.init) ?? "unknown"
    }

    private func readLogTail() -> String {
        guard let logURL = newestLogURL() else { return "" }
        let result = shell(["/usr/bin/tail", "-n", "180", logURL.path])
        return result.output
    }

    private func newestLogURL() -> URL? {
        let logsURL = URL(fileURLWithPath: "\(repositoryPath)/worker/logs", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: logsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "log" }
            .max {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs < rhs
            }
    }

    private func parseCurrentJob(from log: String) -> String {
        let lines = log.split(separator: "\n").map(String.init)
        if let claimed = lines.last(where: { $0.hasPrefix("claimed job ") }) {
            return claimed
        }
        if lines.contains(where: { $0.contains("no pending job") }) {
            return "No pending job."
        }
        return "No active job detected."
    }

    private func handle(_ result: ShellResult) {
        guard result.exitCode != 0 else { return }
        errorMessage = result.output.isEmpty ? "Command exited with \(result.exitCode)." : result.output
        showsError = true
    }

    private func shell(_ arguments: [String]) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return ShellResult(exitCode: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        } catch {
            return ShellResult(exitCode: -1, output: error.localizedDescription)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

private struct ShellResult {
    let exitCode: Int32
    let output: String
}

private extension String {
    var shellQuoted: String {
        "'\(replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
