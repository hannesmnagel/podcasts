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

enum DownloadSettings {
    private static let globalPolicyKey = "downloadSettings.globalPolicy"

    static var globalPolicy: EpisodeDownloadPolicy {
        get {
            UserDefaults.standard.string(forKey: globalPolicyKey).flatMap(EpisodeDownloadPolicy.init(rawValue:)) ?? .manual
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: globalPolicyKey)
        }
    }

    static func policy(for subscription: PodcastSubscription?) -> EpisodeDownloadPolicy {
        subscription?.downloadPolicyRawValue.flatMap(EpisodeDownloadPolicy.init(rawValue:)) ?? globalPolicy
    }

    static func setPolicy(_ policy: EpisodeDownloadPolicy?, for subscription: PodcastSubscription) {
        subscription.downloadPolicyRawValue = policy?.rawValue
    }
}

enum PlaybackSettings {
    private static let globalSpeedKey = "playbackSettings.globalSpeed"
    private static let defaultSpeed = 1.7

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
