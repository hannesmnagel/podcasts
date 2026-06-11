import AppIntents
import Foundation
import PodcatcherKit

// MARK: - Transport intents (also defined in PodcatcherWidgets for widget button use)

struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Toggles playback in The Podcatcher.")
    static let isDiscoverable = true
    init() {}
    func perform() async throws -> some IntentResult {
        postWidgetCommand("playpause")
        return .result()
    }
}

struct SkipForwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Forward"
    static let description = IntentDescription("Skips forward in the current episode.")
    static let isDiscoverable = true
    @Parameter(title: "Seconds", default: 30) var seconds: Int
    init() {}
    init(seconds: Int) { self.seconds = seconds }
    func perform() async throws -> some IntentResult {
        postWidgetCommand("skipforward:\(seconds)")
        return .result()
    }
}

struct SkipBackIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Back"
    static let description = IntentDescription("Skips back in the current episode.")
    static let isDiscoverable = true
    @Parameter(title: "Seconds", default: 15) var seconds: Int
    init() {}
    init(seconds: Int) { self.seconds = seconds }
    func perform() async throws -> some IntentResult {
        postWidgetCommand("skipback:\(seconds)")
        return .result()
    }
}

// MARK: - App-only intents (require the app to be open / have SwiftData context)

struct ContinueListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Listening"
    static let description = IntentDescription("Resumes the most recent in-progress episode.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        return .result()
    }
}

struct PlayPodcastIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Podcast"
    static let description = IntentDescription("Opens a podcast in The Podcatcher.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Podcast")
    var podcast: PodcastEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        return .result()
    }
}

struct SetPlaybackSpeedIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Playback Speed"
    static let description = IntentDescription("Sets the playback speed.")
    static let isDiscoverable = true

    @Parameter(title: "Speed", default: 1.0)
    var speed: Double

    @MainActor
    func perform() async throws -> some IntentResult {
        AppDependencies.shared.player?.speed = Float(speed)
        return .result()
    }
}
