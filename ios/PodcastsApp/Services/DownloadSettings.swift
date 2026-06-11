import Foundation

enum EpisodeDownloadPolicy: String, CaseIterable {
    case manual
    case latest
    case unplayed
    case all

    var title: String {
        switch self {
        case .manual: "Manual"
        case .latest: "Latest Episode"
        case .unplayed: "All Unplayed"
        case .all: "All Episodes"
        }
    }

    var detail: String {
        switch self {
        case .manual: "Only download when you choose it."
        case .latest: "Keep the newest episode downloaded."
        case .unplayed: "Download episodes until they are marked played."
        case .all: "Download every fetched episode."
        }
    }
}

enum CompletedDownloadCleanupPolicy: String, CaseIterable {
    case manual
    case afterPlaybackCompletes

    var title: String {
        switch self {
        case .manual: "Manually"
        case .afterPlaybackCompletes: "After Playback Completes"
        }
    }

    var detail: String {
        switch self {
        case .manual: "Keep downloads until you remove them."
        case .afterPlaybackCompletes: "Delete the local audio file when an episode finishes."
        }
    }
}

enum DownloadSettings {
    private static let globalPolicyKey = "downloadSettings.globalPolicy"
    private static let completedCleanupPolicyKey = "downloadSettings.completedCleanupPolicy"
    private static let allowsBackgroundDownloadsKey = "downloadSettings.allowsBackgroundDownloads"
    private static let allowsCellularDownloadsKey = "downloadSettings.allowsCellularDownloads"
    private static let allowsLowDataModeDownloadsKey = "downloadSettings.allowsLowDataModeDownloads"
    private static let preloadsNextEpisodeKey = "downloadSettings.preloadsNextEpisode"

    static var globalPolicy: EpisodeDownloadPolicy {
        get {
            UserDefaults.standard.string(forKey: globalPolicyKey).flatMap(EpisodeDownloadPolicy.init(rawValue:)) ?? .manual
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: globalPolicyKey)
        }
    }

    static var completedCleanupPolicy: CompletedDownloadCleanupPolicy {
        get {
            UserDefaults.standard.string(forKey: completedCleanupPolicyKey).flatMap(CompletedDownloadCleanupPolicy.init(rawValue:)) ?? .manual
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: completedCleanupPolicyKey)
        }
    }

    static var allowsBackgroundDownloads: Bool {
        get { bool(forKey: allowsBackgroundDownloadsKey, defaultValue: true) }
        set { UserDefaults.standard.set(newValue, forKey: allowsBackgroundDownloadsKey) }
    }

    static var allowsCellularDownloads: Bool {
        get { bool(forKey: allowsCellularDownloadsKey, defaultValue: true) }
        set { UserDefaults.standard.set(newValue, forKey: allowsCellularDownloadsKey) }
    }

    static var allowsLowDataModeDownloads: Bool {
        get { bool(forKey: allowsLowDataModeDownloadsKey, defaultValue: false) }
        set { UserDefaults.standard.set(newValue, forKey: allowsLowDataModeDownloadsKey) }
    }

    static var preloadsNextEpisode: Bool {
        get { bool(forKey: preloadsNextEpisodeKey, defaultValue: true) }
        set { UserDefaults.standard.set(newValue, forKey: preloadsNextEpisodeKey) }
    }

    static func policy(for subscription: PodcastSubscription?) -> EpisodeDownloadPolicy {
        subscription?.downloadPolicyRawValue.flatMap(EpisodeDownloadPolicy.init(rawValue:)) ?? globalPolicy
    }

    static func setPolicy(_ policy: EpisodeDownloadPolicy?, for subscription: PodcastSubscription) {
        subscription.downloadPolicyRawValue = policy?.rawValue
    }

    private static func bool(forKey key: String, defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }
}

enum PlaybackSettings {
    private static let globalSpeedKey = "playbackSettings.globalSpeed"
    private static let defaultSpeed = 1.7
    private static let continueWithNewestKey = "playbackSettings.continueWithNewest"
    private static let sleepRecoveryKey = "playbackSettings.sleepRecovery"
    private static let lastHandledSleepOnsetKey = "playbackSettings.lastHandledSleepOnset"

    static var sleepRecoveryEnabled: Bool {
        get { UserDefaults.standard.object(forKey: sleepRecoveryKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: sleepRecoveryKey) }
    }

    static var lastHandledSleepOnset: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: lastHandledSleepOnsetKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: lastHandledSleepOnsetKey)
        }
    }

    static var continueWithNewestEpisode: Bool {
        get { UserDefaults.standard.bool(forKey: continueWithNewestKey) }
        set { UserDefaults.standard.set(newValue, forKey: continueWithNewestKey) }
    }

    static var globalSpeed: Double {
        get {
            let value = UserDefaults.standard.double(forKey: globalSpeedKey)
            return value > 0 ? value : defaultSpeed
        }
        set {
            UserDefaults.standard.set(clampedSpeed(newValue), forKey: globalSpeedKey)
        }
    }

    static func speed(for subscription: PodcastSubscription?) -> Double {
        clampedSpeed(subscription?.playbackSpeed ?? globalSpeed)
    }

    static func usesCustomSpeed(for subscription: PodcastSubscription?) -> Bool {
        subscription?.playbackSpeed != nil
    }

    static func setSpeed(_ speed: Double, for subscription: PodcastSubscription?, customForPodcast: Bool) {
        let speed = clampedSpeed(speed)
        if customForPodcast, let subscription {
            subscription.playbackSpeed = speed
        } else {
            subscription?.playbackSpeed = nil
            globalSpeed = speed
        }
    }

    static func setUsesCustomSpeed(_ usesCustom: Bool, for subscription: PodcastSubscription?, currentSpeed: Double) {
        guard let subscription else { return }
        subscription.playbackSpeed = usesCustom ? clampedSpeed(currentSpeed) : nil
    }

    static func clampedSpeed(_ speed: Double) -> Double {
        min(5, max(0.5, speed))
    }
}

enum SeekSettings {
    private static let backKey = "seekSettings.backSeconds"
    private static let forwardKey = "seekSettings.forwardSeconds"

    static var backSeconds: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: backKey)
            return value > 0 ? value : 15
        }
        set {
            UserDefaults.standard.set(clamped(newValue), forKey: backKey)
        }
    }

    static var forwardSeconds: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: forwardKey)
            return value > 0 ? value : 30
        }
        set {
            UserDefaults.standard.set(clamped(newValue), forKey: forwardKey)
        }
    }

    private static func clamped(_ value: TimeInterval) -> TimeInterval {
        min(120, max(5, value.rounded()))
    }
}

struct OPMLSubscription: Hashable, Sendable {
    let title: String?
    let feedURL: URL
}

enum OPMLParser {
    static func subscriptions(from data: Data) -> [OPMLSubscription] {
        let delegate = OPMLDocumentParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.subscriptions
    }
}

private final class OPMLDocumentParser: NSObject, XMLParserDelegate {
    private(set) var subscriptions: [OPMLSubscription] = []
    private var seenFeedURLs: Set<URL> = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName.lowercased() == "outline",
              let xmlURL = attributeDict["xmlUrl"] ?? attributeDict["xmlurl"],
              let feedURL = URL(string: xmlURL),
              !seenFeedURLs.contains(feedURL) else {
            return
        }
        seenFeedURLs.insert(feedURL)
        let title = attributeDict["title"] ?? attributeDict["text"]
        subscriptions.append(OPMLSubscription(title: title, feedURL: feedURL))
    }
}
