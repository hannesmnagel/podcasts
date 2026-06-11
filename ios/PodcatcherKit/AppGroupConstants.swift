import Foundation

public enum AppGroupConstants {
    public static let identifier = "group.com.nagel.podcasts"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static let playbackStateKey = "SharedPlaybackState"
    static let librarySnapshotFileName = "library-snapshot.json"

    // Widget → app command channel
    public static let widgetCommandNotification = "com.nagel.podcasts.widgetCommand"
    public static let widgetCommandKey = "pendingWidgetCommand"
    public static let widgetCommandTimeKey = "pendingWidgetCommandTime"

}
