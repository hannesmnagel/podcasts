import Foundation
import Combine

struct DownloadProgress: Sendable {
    let id: String
    let title: String?
    let fractionCompleted: Double
    let completedBytes: Int64
    let totalBytes: Int64?
    let isFinished: Bool

    var percentText: String {
        "\(Int((fractionCompleted * 100).rounded()))%"
    }
}

@MainActor
final class DownloadProgressCenter {
    static let shared = DownloadProgressCenter()

    @Published private(set) var progresses: [String: DownloadProgress] = [:]

    private init() {}

    func begin(id: String, title: String?) {
        guard progresses[id] == nil else { return }
        progresses[id] = DownloadProgress(
            id: id,
            title: title,
            fractionCompleted: 0,
            completedBytes: 0,
            totalBytes: nil,
            isFinished: false
        )
    }

    func update(id: String, completedBytes: Int64, totalBytes: Int64?) {
        let total = totalBytes.flatMap { $0 > 0 ? $0 : nil }
        let fraction = total.map { min(1, max(0, Double(completedBytes) / Double($0))) } ?? 0
        let current = progresses[id]
        progresses[id] = DownloadProgress(
            id: id,
            title: current?.title,
            fractionCompleted: fraction,
            completedBytes: completedBytes,
            totalBytes: total,
            isFinished: false
        )
    }

    func finish(id: String) {
        let current = progresses[id]
        progresses[id] = DownloadProgress(
            id: id,
            title: current?.title,
            fractionCompleted: 1,
            completedBytes: current?.completedBytes ?? current?.totalBytes ?? 0,
            totalBytes: current?.totalBytes,
            isFinished: true
        )
    }

    func clear(id: String) {
        progresses[id] = nil
    }

    func clear(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        progresses = progresses.filter { key, _ in !ids.contains(key) }
    }
}

enum LocalMediaCache {
    static func cachedFileURL(for remoteURL: URL) -> URL {
        cacheDirectory
            .appendingPathComponent(fileName(for: remoteURL), isDirectory: false)
    }

    static func cachedOrDownload(_ remoteURL: URL, progressID: String? = nil) async throws -> URL {
        let destination = cachedFileURL(for: remoteURL)
        if await fileExists(at: destination) {
            if let progressID {
                await DownloadProgressCenter.shared.finish(id: progressID)
            }
            return destination
        }

        try await createCacheDirectory()
        let temporaryURL = try await ProgressReportingDownloader.download(from: remoteURL, progressID: progressID)
        if await fileExists(at: destination) {
            try? await removeFile(at: temporaryURL)
            if let progressID {
                await DownloadProgressCenter.shared.finish(id: progressID)
            }
            return destination
        }
        try await moveFile(from: temporaryURL, to: destination)
        if let progressID {
            await DownloadProgressCenter.shared.finish(id: progressID)
        }
        return destination
    }

    static func removeCachedFile(for remoteURL: URL) async {
        try? await removeFile(at: cachedFileURL(for: remoteURL))
    }

    static func cancelDownload(progressID: String) async {
        ProgressReportingDownloader.cancel(progressID: progressID)
        await DownloadProgressCenter.shared.clear(id: progressID)
    }

    static func cancelDownloads(progressIDs: Set<String>) async {
        for progressID in progressIDs {
            ProgressReportingDownloader.cancel(progressID: progressID)
        }
        await DownloadProgressCenter.shared.clear(ids: progressIDs)
    }

    static func removeFileIfPresent(at url: URL) async {
        try? await removeFile(at: url)
    }

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PodcastMediaCache", isDirectory: true)
    }

    private static func fileName(for url: URL) -> String {
        let encoded = Data(url.absoluteString.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        let pathExtension = url.pathExtension.isEmpty ? "img" : url.pathExtension
        return "\(encoded).\(pathExtension)"
    }

    @concurrent
    private static func fileExists(at url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @concurrent
    private static func createCacheDirectory() async throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    @concurrent
    private static func moveFile(from source: URL, to destination: URL) async throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    @concurrent
    private static func removeFile(at url: URL) async throws {
        try FileManager.default.removeItem(at: url)
    }
}

private final class ProgressReportingDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private static let activeLock = NSLock()
    nonisolated(unsafe) private static var activeSessions: [String: URLSession] = [:]

    private let progressID: String?
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    init(progressID: String?) {
        self.progressID = progressID
    }

    static func download(from url: URL, progressID: String?) async throws -> URL {
        let downloader = ProgressReportingDownloader(progressID: progressID)
        return try await downloader.download(from: url)
    }

    static func cancel(progressID: String) {
        activeLock.lock()
        let session = activeSessions.removeValue(forKey: progressID)
        activeLock.unlock()
        session?.invalidateAndCancel()
    }

    private static func register(_ session: URLSession, progressID: String?) {
        guard let progressID else { return }
        activeLock.lock()
        activeSessions[progressID] = session
        activeLock.unlock()
    }

    private static func unregister(progressID: String?) {
        guard let progressID else { return }
        activeLock.lock()
        activeSessions[progressID] = nil
        activeLock.unlock()
    }

    private func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            Self.register(session, progressID: progressID)
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let progressID else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        Task { @MainActor in
            DownloadProgressCenter.shared.update(id: progressID, completedBytes: totalBytesWritten, totalBytes: total)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let continuation else { return }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(location.pathExtension)
        do {
            try FileManager.default.moveItem(at: location, to: temporaryURL)
            continuation.resume(returning: temporaryURL)
        } catch {
            continuation.resume(throwing: error)
        }
        self.continuation = nil
        Self.unregister(progressID: progressID)
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let continuation else { return }
        continuation.resume(throwing: error)
        self.continuation = nil
        Self.unregister(progressID: progressID)
        session.invalidateAndCancel()
    }
}
