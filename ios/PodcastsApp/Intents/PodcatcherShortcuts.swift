import AppIntents
import PodcatcherKit

struct PodcatcherShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayPauseIntent(),
            phrases: [
                "Play in \(.applicationName)",
                "Pause in \(.applicationName)",
                "Toggle playback in \(.applicationName)"
            ],
            shortTitle: "Play / Pause",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: ContinueListeningIntent(),
            phrases: [
                "Continue listening in \(.applicationName)",
                "Resume podcast in \(.applicationName)"
            ],
            shortTitle: "Continue Listening",
            systemImageName: "headphones"
        )
        AppShortcut(
            intent: SkipForwardIntent(),
            phrases: ["Skip forward in \(.applicationName)"],
            shortTitle: "Skip Forward",
            systemImageName: "goforward.30"
        )
        AppShortcut(
            intent: SkipBackIntent(),
            phrases: ["Skip back in \(.applicationName)"],
            shortTitle: "Skip Back",
            systemImageName: "gobackward.15"
        )
    }
}
