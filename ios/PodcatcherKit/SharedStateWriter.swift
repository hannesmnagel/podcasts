import Foundation

@MainActor
public final class SharedStateWriter {
    private let defaults = UserDefaults(suiteName: AppGroupConstants.identifier)
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public init() {}

    public func writePlaybackState(_ state: SharedPlaybackState) {
        guard let data = try? encoder.encode(state) else { return }
        defaults?.set(data, forKey: AppGroupConstants.playbackStateKey)
    }

    public func writeLibrarySnapshot(_ snapshot: SharedLibrarySnapshot) {
        guard let containerURL = AppGroupConstants.containerURL,
              let data = try? encoder.encode(snapshot) else { return }
        let fileURL = containerURL.appendingPathComponent(AppGroupConstants.librarySnapshotFileName)
        try? data.write(to: fileURL, options: .atomic)
    }
}
