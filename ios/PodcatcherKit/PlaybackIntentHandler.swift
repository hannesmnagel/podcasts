#if canImport(AppIntents)
import AppIntents
import Foundation

// MARK: - Handler (registered by the main app, invoked by intents)

@MainActor
public final class PlaybackIntentHandler {
    public static let shared = PlaybackIntentHandler()
    private init() {}

    public var onPlayPause: (() -> Void)?
    public var onSkipForward: ((TimeInterval) -> Void)?
    public var onSkipBack: ((TimeInterval) -> Void)?

    public func playPause() { onPlayPause?() }
    public func skipForward(_ seconds: TimeInterval) { onSkipForward?(seconds) }
    public func skipBack(_ seconds: TimeInterval) { onSkipBack?(seconds) }
}

public func postWidgetCommand(_ command: String) {
    let defaults = UserDefaults(suiteName: AppGroupConstants.identifier)
    defaults?.set(command, forKey: AppGroupConstants.widgetCommandKey)
    defaults?.set(Date().timeIntervalSince1970, forKey: AppGroupConstants.widgetCommandTimeKey)
    defaults?.synchronize()
    // CFNotificationCenter Darwin center is cross-process and wakes suspended apps.
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(AppGroupConstants.widgetCommandNotification as CFString),
        nil, nil, true
    )
}
#endif
