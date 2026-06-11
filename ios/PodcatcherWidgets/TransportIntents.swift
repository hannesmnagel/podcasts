import AppIntents
import PodcatcherKit

// Intent types must live in the widget extension binary itself so Xcode's
// AppIntents metadata extractor picks them up at build time. Intents defined
// only in a linked dynamic framework are invisible to the extractor and
// Button(intent:) silently does nothing.

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

struct SetPlayingIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Toggle Playback"

    @Parameter(title: "Playing") var value: Bool

    init() { value = false }

    func perform() async throws -> some IntentResult {
        postWidgetCommand("playpause")
        return .result()
    }
}

struct SkipForwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Forward"
    static let description = IntentDescription("Skips forward in the current episode.")
    static let isDiscoverable = true

    @Parameter(title: "Seconds", default: 30)
    var seconds: Int

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

    @Parameter(title: "Seconds", default: 15)
    var seconds: Int

    init() {}
    init(seconds: Int) { self.seconds = seconds }

    func perform() async throws -> some IntentResult {
        postWidgetCommand("skipback:\(seconds)")
        return .result()
    }
}
