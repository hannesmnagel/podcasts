import BackgroundTasks
import SwiftData
import UIKit

@main
final class PodcastsAppDelegate: UIResponder, UIApplicationDelegate {
    private static let backgroundRefreshTaskIdentifier = "com.nagel.podcasts.refresh"

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

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        registerBackgroundTasks()
        Self.configureBackgroundRefresh()
        return true
    }

    static func configureBackgroundRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundRefreshTaskIdentifier)
        guard DownloadSettings.allowsBackgroundDownloads else { return }

        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundRefreshTaskIdentifier, using: nil) { [weak self] task in
            guard let self, let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleBackgroundRefresh(refreshTask)
        }
    }

    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        Self.configureBackgroundRefresh()
        let refresh = Task { @MainActor in
            await Self.refreshAndApplyDownloadPolicies(context: modelContainer.mainContext)
        }
        task.expirationHandler = {
            refresh.cancel()
        }
        Task {
            let success = await refresh.value
            task.setTaskCompleted(success: success)
        }
    }

    @MainActor
    private static func refreshAndApplyDownloadPolicies(context: ModelContext) async -> Bool {
        guard !NetworkMonitor.shared.isOffline else { return false }
        let client = BackendClient()
        var descriptor = FetchDescriptor<PodcastSubscription>(sortBy: [SortDescriptor(\.sortIndex)])
        descriptor.includePendingChanges = true
        let subscriptions = (try? context.fetch(descriptor)) ?? []
        guard !subscriptions.isEmpty else { return false }

        var changed = false
        for subscription in subscriptions {
            guard !Task.isCancelled else { return changed }
            await client.requestPodcastCrawl(subscription.stableID)
            guard let fetched = try? await client.episodes(for: subscription.stableID) else {
                await Task.yield()
                continue
            }
            await LibraryStore.cacheEpisodes(fetched, in: context)
            let localEpisodes = LibraryStore.localEpisodes(forPodcastIDs: [subscription.stableID], in: context)
            let downloaded = await LibraryStore.applyDownloadPolicy(to: localEpisodes, subscription: subscription, in: context)
            changed = changed || downloaded > 0 || !fetched.isEmpty
            await Task.yield()
        }

        return changed
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
        (UIApplication.shared.delegate as? PodcastsAppDelegate)?.player.refreshSystemPlaybackIntegration()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        (window?.rootViewController as? RootTabController)?.persistCurrentPlaybackState()
        PodcastsAppDelegate.configureBackgroundRefresh()
    }
}
