import Foundation

enum LocalMediaCache {
    static func cachedFileURL(for remoteURL: URL) -> URL {
        cacheDirectory
            .appendingPathComponent(fileName(for: remoteURL), isDirectory: false)
    }

    static func cachedOrDownload(_ remoteURL: URL) async throws -> URL {
        let destination = cachedFileURL(for: remoteURL)
        if await fileExists(at: destination) {
            return destination
        }

        try await createCacheDirectory()
        let (temporaryURL, _) = try await URLSession.shared.download(from: remoteURL)
        if await fileExists(at: destination) {
            try? await removeFile(at: temporaryURL)
            return destination
        }
        try await moveFile(from: temporaryURL, to: destination)
        return destination
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
