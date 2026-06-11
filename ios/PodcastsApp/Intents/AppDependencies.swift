import Foundation
import UIKit

/// Lightweight bridge that lets App Intents access PlayerController without UIKit scene coupling.
@MainActor
final class AppDependencies {
    static let shared = AppDependencies()
    private init() {}

    var player: PlayerController? {
        (UIApplication.shared.delegate as? PodcastsAppDelegate)?.player
    }
}
