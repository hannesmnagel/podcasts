import SwiftData
import UIKit

@main
final class PodcastsAppDelegate: UIResponder, UIApplicationDelegate {
    let modelContainer: ModelContainer
    let player = PlayerController()

    override init() {
        do {
            modelContainer = try ModelContainer(for: PodcastSubscription.self, LocalEpisodeState.self, LocalEpisodeArtifact.self, Playlist.self)
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
        super.init()
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = PodcastsSceneDelegate.self
        return configuration
    }
}

final class PodcastsSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene,
              let appDelegate = UIApplication.shared.delegate as? PodcastsAppDelegate else {
            return
        }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = RootTabController(modelContext: appDelegate.modelContainer.mainContext, player: appDelegate.player)
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        (window?.rootViewController as? RootTabController)?.persistCurrentPlaybackState()
    }
}
