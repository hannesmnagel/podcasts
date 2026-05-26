import Foundation
import MetricKit
import OSLog
import UIKit
import Darwin

final class DiagnosticsCenter: NSObject, @unchecked Sendable {
    static let shared = DiagnosticsCenter()
    private static let sessionKey = "diagnostics.currentSessionID"
    private static let sessionCleanExitKey = "diagnostics.currentSessionCleanExit"
    private static let launchCountKey = "diagnostics.launchCount"
    private static let crashMarkerFileName = "last_fatal_signal.txt"

    private let queue = DispatchQueue(label: "com.nagel.podcasts.diagnostics")
    private let logger = Logger(subsystem: "com.nagel.podcasts", category: "diagnostics")
    private let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private lazy var logsDirectoryURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private lazy var logFileURL: URL = logsDirectoryURL.appendingPathComponent("app.log")
    private lazy var metricPayloadsFileURL: URL = logsDirectoryURL.appendingPathComponent("metric_payloads.jsonl")
    private lazy var crashMarkerFileURL: URL = logsDirectoryURL.appendingPathComponent(Self.crashMarkerFileName)

    private var didStart = false
    private var currentSessionID = UUID().uuidString
    private var logWritesSinceTrim = 0
    private var metricWritesSinceTrim = 0

    func start() {
        queue.async {
            guard !self.didStart else { return }
            self.didStart = true
            self.installCrashSignalHandlers()
            self.installExceptionHandler()
            self.installSystemObservers()
            MXMetricManager.shared.add(self)
            self.recordSessionStart()
            self.log("Diagnostics initialized")
        }
    }

    func log(_ message: String) {
        queue.async {
            self.logger.info("\(message, privacy: .public)")
            let line = "\(self.iso8601.string(from: Date())) \(message)\n"
            self.append(line: line, to: self.logFileURL)
            self.logWritesSinceTrim += 1
            if self.logWritesSinceTrim >= 50 {
                self.logWritesSinceTrim = 0
                self.trimFileIfNeeded(at: self.logFileURL, maxBytes: 1_000_000, keepBytes: 750_000)
            }
        }
    }

    func exportDiagnosticsBundle() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let fileManager = FileManager.default
                    let dateStamp = self.iso8601.string(from: Date()).replacingOccurrences(of: ":", with: "-")
                    let exportDirectory = fileManager.temporaryDirectory.appendingPathComponent("podcasts-diagnostics-\(dateStamp)", isDirectory: true)
                    if fileManager.fileExists(atPath: exportDirectory.path) {
                        try fileManager.removeItem(at: exportDirectory)
                    }
                    try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

                    if fileManager.fileExists(atPath: self.logFileURL.path) {
                        try fileManager.copyItem(at: self.logFileURL, to: exportDirectory.appendingPathComponent("app.log"))
                    }
                    if fileManager.fileExists(atPath: self.metricPayloadsFileURL.path) {
                        try fileManager.copyItem(at: self.metricPayloadsFileURL, to: exportDirectory.appendingPathComponent("metric_payloads.jsonl"))
                    }
                    if fileManager.fileExists(atPath: self.crashMarkerFileURL.path) {
                        try fileManager.copyItem(at: self.crashMarkerFileURL, to: exportDirectory.appendingPathComponent(Self.crashMarkerFileName))
                    }

                    let metadataURL = exportDirectory.appendingPathComponent("metadata.txt")
                    let metadata = [
                        "bundle_id=\(Bundle.main.bundleIdentifier ?? "unknown")",
                        "version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")",
                        "build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")",
                        "exported_at=\(self.iso8601.string(from: Date()))"
                    ].joined(separator: "\n") + "\n"
                    try metadata.write(to: metadataURL, atomically: true, encoding: .utf8)
                    continuation.resume(returning: exportDirectory)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func markCleanExit(reason: String) {
        queue.async {
            UserDefaults.standard.set(true, forKey: Self.sessionCleanExitKey)
            self.log("session clean-exit reason=\(reason) session=\(self.currentSessionID)")
        }
    }

    private func recordSessionStart() {
        let defaults = UserDefaults.standard
        let previousSessionID = defaults.string(forKey: Self.sessionKey)
        let previousCleanExit = defaults.object(forKey: Self.sessionCleanExitKey) as? Bool ?? true
        let launchCount = defaults.integer(forKey: Self.launchCountKey) + 1
        defaults.set(launchCount, forKey: Self.launchCountKey)
        defaults.set(currentSessionID, forKey: Self.sessionKey)
        defaults.set(false, forKey: Self.sessionCleanExitKey)

        let memory = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        log("session start id=\(currentSessionID) launch_count=\(launchCount) thermal=\(thermal) physical_memory_mb=\(memory)")
        if let previousSessionID {
            log("previous session id=\(previousSessionID) clean_exit=\(previousCleanExit)")
            if !previousCleanExit {
                log("possible crash/termination detected previous_session_unclean=true")
            }
        }
    }

    private func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            DiagnosticsCenter.shared.log("uncaught exception name=\(exception.name.rawValue) reason=\(exception.reason ?? "unknown") stack=\(exception.callStackSymbols.joined(separator: " | "))")
        }
    }

    private func installCrashSignalHandlers() {
        CrashSignalHandler.install(crashMarkerFileURL: crashMarkerFileURL)
    }

    private func installSystemObservers() {
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            DiagnosticsCenter.shared.log("system warning type=memory")
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
            DiagnosticsCenter.shared.log("system state thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
        }
    }

    private func append(line: String, to fileURL: URL) {
        let data = Data(line.utf8)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } catch {
                    logger.error("Failed writing diagnostics log: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }

        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            logger.error("Failed creating diagnostics log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func trimFileIfNeeded(at url: URL, maxBytes: Int, keepBytes: Int) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue > maxBytes else {
            return
        }

        do {
            guard let readHandle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? readHandle.close() }
            let size = Int64(fileSize.intValue)
            let suffixCount = min(keepBytes, fileSize.intValue)
            let startOffset = max(0, size - Int64(suffixCount))
            try readHandle.seek(toOffset: UInt64(startOffset))
            let suffixData = try readHandle.readToEnd() ?? Data()
            let header = "\(iso8601.string(from: Date())) [log-trimmed] kept_last_bytes=\(suffixData.count)\n"

            guard let writeHandle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? writeHandle.close() }
            try writeHandle.truncate(atOffset: 0)
            try writeHandle.seek(toOffset: 0)
            try writeHandle.write(contentsOf: Data(header.utf8))
            try writeHandle.write(contentsOf: suffixData)
        } catch {
            logger.error("Failed trimming diagnostics file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func appendMetricPayload(_ payload: MXDiagnosticPayload) {
        let payloadData = payload.jsonRepresentation()
        if let payloadString = String(data: payloadData, encoding: .utf8) {
            append(line: payloadString, to: metricPayloadsFileURL)
            append(line: "\n", to: metricPayloadsFileURL)
            metricWritesSinceTrim += 1
            if metricWritesSinceTrim >= 2 {
                metricWritesSinceTrim = 0
                trimFileIfNeeded(at: metricPayloadsFileURL, maxBytes: 2_000_000, keepBytes: 1_500_000)
            }
        }
    }
}

extension DiagnosticsCenter: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        log("Received MetricKit payloads count=\(payloads.count)")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        queue.async {
            self.log("Received crash diagnostics payloads count=\(payloads.count)")
            payloads.forEach(self.appendMetricPayload)
        }
    }
}

private enum CrashSignalHandler {
    private static let queue = DispatchQueue(label: "com.nagel.podcasts.diagnostics.signal")
    nonisolated(unsafe) private static var crashMarkerPath: String = ""

    static func install(crashMarkerFileURL: URL) {
        queue.sync {
            crashMarkerPath = crashMarkerFileURL.path
            [SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGTRAP].forEach { signal($0, handleSignal) }
        }
    }

    private static let handleSignal: @convention(c) (Int32) -> Void = { signalNumber in
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(timestamp) fatal signal=\(signalNumber)\n"
        if !crashMarkerPath.isEmpty {
            text.withCString { chars in
                let fd = open(crashMarkerPath, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
                if fd >= 0 {
                    _ = write(fd, chars, strlen(chars))
                    close(fd)
                }
            }
        }
        signal(signalNumber, SIG_DFL)
        raise(signalNumber)
    }
}
