import Foundation
import Combine
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

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

    func fail(id: String) {
        clear(id: id)
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

    static func existingCachedFileURL(for remoteURL: URL) async -> URL? {
        let destination = cachedFileURL(for: remoteURL)
        if await fileExists(at: destination) {
            return destination
        }
        let legacyDestination = legacyCachedFileURL(for: remoteURL)
        return await fileExists(at: legacyDestination) ? legacyDestination : nil
    }

    static func cachedOrDownload(_ remoteURL: URL, progressID: String? = nil) async throws -> URL {
        let destination = cachedFileURL(for: remoteURL)
        if await fileExists(at: destination) {
            if let progressID {
                await DownloadProgressCenter.shared.finish(id: progressID)
            }
            return destination
        }
        let legacyDestination = legacyCachedFileURL(for: remoteURL)
        if await fileExists(at: legacyDestination) {
            if let progressID {
                await DownloadProgressCenter.shared.finish(id: progressID)
            }
            return legacyDestination
        }

        guard !NetworkMonitor.shared.isOffline else {
            throw URLError(.notConnectedToInternet)
        }

        try await createCacheDirectory()
        let temporaryURL = try await DownloadCoordinator.shared.download(from: remoteURL, progressID: progressID)
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
        try? await removeFile(at: legacyCachedFileURL(for: remoteURL))
    }

    static func cancelDownload(progressID: String) async {
        await DownloadCoordinator.shared.cancel(progressID: progressID)
        await DownloadProgressCenter.shared.clear(id: progressID)
    }

    static func cancelDownloads(progressIDs: Set<String>) async {
        for progressID in progressIDs {
            await DownloadCoordinator.shared.cancel(progressID: progressID)
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
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(digest).\(pathExtension(for: url))"
    }

    private static func legacyCachedFileURL(for remoteURL: URL) -> URL {
        cacheDirectory
            .appendingPathComponent(legacyFileName(for: remoteURL), isDirectory: false)
    }

    private static func legacyFileName(for url: URL) -> String {
        let encoded = Data(url.absoluteString.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "\(encoded).\(pathExtension(for: url))"
    }

    private static func pathExtension(for url: URL) -> String {
        url.pathExtension.isEmpty ? "img" : url.pathExtension
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
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    @concurrent
    private static func removeFile(at url: URL) async throws {
        try FileManager.default.removeItem(at: url)
    }
}

private actor DownloadCoordinator {
    static let shared = DownloadCoordinator()

    private struct ActiveDownload {
        let task: Task<URL, Error>
        var progressIDs: Set<String>
    }

    private var activeDownloads: [String: ActiveDownload] = [:]
    private var progressIDToKeys: [String: Set<String>] = [:]

    func download(from url: URL, progressID: String?) async throws -> URL {
        let key = cacheKey(for: url)
        if let progressID {
            add(progressID: progressID, for: key)
        }

        if let active = activeDownloads[key] {
            return try await active.task.value
        }

        let task = Task<URL, Error> {
            try await ProgressReportingDownloader.download(from: url, cacheKey: key)
        }
        activeDownloads[key] = ActiveDownload(task: task, progressIDs: progressID.map { [$0] } ?? [])

        do {
            let temporaryURL = try await task.value
            await finishProgress(for: key)
            removeDownload(for: key)
            return temporaryURL
        } catch {
            await failProgress(for: key)
            removeDownload(for: key)
            throw error
        }
    }

    func progressIDs(for key: String) -> Set<String> {
        activeDownloads[key]?.progressIDs ?? []
    }

    func cancel(progressID: String) {
        let keys = progressIDToKeys[progressID] ?? []
        progressIDToKeys[progressID] = nil
        for key in keys {
            activeDownloads[key]?.task.cancel()
            ProgressReportingDownloader.cancel(cacheKey: key)
            activeDownloads[key] = nil
        }
    }

    private func add(progressID: String, for key: String) {
        var active = activeDownloads[key]
        active?.progressIDs.insert(progressID)
        if let active {
            activeDownloads[key] = active
        }
        progressIDToKeys[progressID, default: []].insert(key)
    }

    private func removeDownload(for key: String) {
        let progressIDs = activeDownloads[key]?.progressIDs ?? []
        for progressID in progressIDs {
            progressIDToKeys[progressID]?.remove(key)
            if progressIDToKeys[progressID]?.isEmpty == true {
                progressIDToKeys[progressID] = nil
            }
        }
        activeDownloads[key] = nil
    }

    private func finishProgress(for key: String) async {
        let ids = progressIDs(for: key)
        await MainActor.run {
            ids.forEach { DownloadProgressCenter.shared.finish(id: $0) }
        }
    }

    private func failProgress(for key: String) async {
        let ids = progressIDs(for: key)
        await MainActor.run {
            ids.forEach { DownloadProgressCenter.shared.fail(id: $0) }
        }
    }

    private func cacheKey(for url: URL) -> String {
        url.absoluteString
    }
}

private final class ProgressReportingDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private static let activeLock = NSLock()
    nonisolated(unsafe) private static var activeSessions: [String: URLSession] = [:]

    private let cacheKey: String
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var responseError: Error?
    private let backgroundActivity = BackgroundDownloadActivity()

    init(cacheKey: String) {
        self.cacheKey = cacheKey
    }

    static func download(from url: URL, cacheKey: String) async throws -> URL {
        let downloader = ProgressReportingDownloader(cacheKey: cacheKey)
        return try await downloader.download(from: url)
    }

    static func cancel(cacheKey: String) {
        activeLock.lock()
        let session = activeSessions.removeValue(forKey: cacheKey)
        activeLock.unlock()
        session?.invalidateAndCancel()
    }

    private static func register(_ session: URLSession, cacheKey: String) {
        activeLock.lock()
        activeSessions[cacheKey] = session
        activeLock.unlock()
    }

    private static func unregister(cacheKey: String) {
        activeLock.lock()
        activeSessions[cacheKey] = nil
        activeLock.unlock()
    }

    private func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            backgroundActivity.begin()
            let configuration = URLSessionConfiguration.default
            configuration.allowsConstrainedNetworkAccess = DownloadSettings.allowsLowDataModeDownloads
            configuration.allowsExpensiveNetworkAccess = DownloadSettings.allowsCellularDownloads
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60 * 60 * 3
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            Self.register(session, cacheKey: cacheKey)
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        Task {
            let progressIDs = await DownloadCoordinator.shared.progressIDs(for: cacheKey)
            await MainActor.run {
                progressIDs.forEach {
                    DownloadProgressCenter.shared.update(id: $0, completedBytes: totalBytesWritten, totalBytes: total)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) else {
            return .allow
        }
        responseError = URLError(.badServerResponse)
        return .cancel
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let continuation else { return }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(location.pathExtension)
        do {
            if let responseError {
                throw responseError
            }
            let values = try location.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) > 0 else {
                throw URLError(.zeroByteResource)
            }
            try FileManager.default.moveItem(at: location, to: temporaryURL)
            continuation.resume(returning: temporaryURL)
        } catch {
            continuation.resume(throwing: error)
        }
        self.continuation = nil
        Self.unregister(cacheKey: cacheKey)
        backgroundActivity.end()
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let continuation else { return }
        continuation.resume(throwing: error)
        self.continuation = nil
        Self.unregister(cacheKey: cacheKey)
        backgroundActivity.end()
        session.invalidateAndCancel()
    }
}

private final class BackgroundDownloadActivity: @unchecked Sendable {
    #if canImport(UIKit)
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        Task { @MainActor in
            guard self.identifier == .invalid else { return }
            self.identifier = UIApplication.shared.beginBackgroundTask(withName: "Podcast Download") { [weak self] in
                self?.end()
            }
        }
    }

    func end() {
        Task { @MainActor in
            guard self.identifier != .invalid else { return }
            let current = self.identifier
            self.identifier = .invalid
            UIApplication.shared.endBackgroundTask(current)
        }
    }
    #else
    func begin() {}
    func end() {}
    #endif
}
