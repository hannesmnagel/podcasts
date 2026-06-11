import Foundation

public enum SharedStateReader {
    // UserDefaults is thread-safe; nonisolated(unsafe) suppresses the strict-concurrency check.
    nonisolated(unsafe) private static let defaults = UserDefaults(suiteName: AppGroupConstants.identifier)
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func currentPlaybackState() -> SharedPlaybackState? {
        guard let data = defaults?.data(forKey: AppGroupConstants.playbackStateKey) else { return nil }
        return try? decoder.decode(SharedPlaybackState.self, from: data)
    }

    public static func librarySnapshot() -> SharedLibrarySnapshot? {
        guard let containerURL = AppGroupConstants.containerURL else { return nil }
        let fileURL = containerURL.appendingPathComponent(AppGroupConstants.librarySnapshotFileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(SharedLibrarySnapshot.self, from: data)
    }
}
