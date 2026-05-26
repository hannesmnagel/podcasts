import BackgroundTasks
import SwiftData
import UIKit

@main
final class PodcastsAppDelegate: UIResponder, UIApplicationDelegate {
    private static let backgroundRefreshTaskIdentifier = "com.nagel.podcasts.refresh"

    let modelContainer: ModelContainer
    let backgroundRefreshStore: BackgroundRefreshStore
    let player = PlayerController()

    override init() {
        do {
            modelContainer = try ModelContainer(for: PodcastSubscription.self, LocalEpisodeState.self, LocalEpisodeArtifact.self, Playlist.self)
            backgroundRefreshStore = BackgroundRefreshStore(modelContainer: modelContainer)
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

    func applicationWillTerminate(_ application: UIApplication) {
        DiagnosticsCenter.shared.markCleanExit(reason: "applicationWillTerminate")
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DiagnosticsCenter.shared.start()
        DiagnosticsCenter.shared.log("didFinishLaunching")
        registerBackgroundTasks()
        Self.configureBackgroundRefresh()
        return true
    }

    static func configureBackgroundRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundRefreshTaskIdentifier)
        guard DownloadSettings.allowsBackgroundDownloads else {
            DiagnosticsCenter.shared.log("background refresh disabled by settings")
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            DiagnosticsCenter.shared.log("background refresh scheduled earliest=15m")
        } catch {
            DiagnosticsCenter.shared.log("background refresh schedule failed error=\(error.localizedDescription)")
        }
    }

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundRefreshTaskIdentifier, using: DispatchQueue.main) { [weak self] task in
            guard let self, let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleBackgroundRefresh(refreshTask)
        }
    }

    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        DiagnosticsCenter.shared.log("background refresh started")
        Self.configureBackgroundRefresh()
        let refresh = Task {
            await backgroundRefreshStore.refreshAndApplyDownloadPolicies()
        }
        task.expirationHandler = {
            refresh.cancel()
        }
        Task {
            let success = await refresh.value
            DiagnosticsCenter.shared.log("background refresh completed success=\(success)")
            task.setTaskCompleted(success: success)
        }
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

    func sceneDidBecomeActive(_ scene: UIScene) {
        DiagnosticsCenter.shared.log("sceneDidBecomeActive")
        (UIApplication.shared.delegate as? PodcastsAppDelegate)?.player.refreshSystemPlaybackIntegration()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        DiagnosticsCenter.shared.log("sceneDidEnterBackground")
        (window?.rootViewController as? RootTabController)?.persistCurrentPlaybackState()
        PodcastsAppDelegate.configureBackgroundRefresh()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        DiagnosticsCenter.shared.markCleanExit(reason: "sceneDidDisconnect")
    }
}
