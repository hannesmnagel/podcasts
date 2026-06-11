import BackgroundTasks
import PodcatcherKit
import SwiftData
import UIKit
import UniformTypeIdentifiers
import WidgetKit

// Top-level C-compatible callback for the Darwin notification from the widget extension.
// CFNotificationCenter requires a plain function pointer; captures are not allowed.
// We route to a global closure set by the app delegate.
nonisolated(unsafe) private var _widgetCommandCallback: (() -> Void)?
private func widgetCommandCFCallback(
    _: CFNotificationCenter?, _: UnsafeMutableRawPointer?,
    _: CFNotificationName?, _: UnsafeRawPointer?, _: CFDictionary?
) {
    _widgetCommandCallback?()
}

@main
final class PodcastsAppDelegate: UIResponder, UIApplicationDelegate {
    private static let backgroundRefreshTaskIdentifier = "com.nagel.podcasts.refresh"

    let modelContainer: ModelContainer
    let backgroundRefreshStore: BackgroundRefreshStore
    let player = PlayerController()
    let eventLogger: EventLogger

    override init() {
        do {
            modelContainer = try ModelContainer(
                for: PodcastSubscription.self, LocalEpisodeState.self, LocalEpisodeArtifact.self,
                    Playlist.self, AppEvent.self, PodcastDailySummary.self,
                configurations: ModelConfiguration(cloudKitDatabase: .automatic)
            )
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
        backgroundRefreshStore = BackgroundRefreshStore(modelContainer: modelContainer)
        eventLogger = EventLogger(context: modelContainer.mainContext)
        super.init()
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        switch options.userActivities.first?.activityType {
        case SettingsSceneDelegate.activityType:    configuration.delegateClass = SettingsSceneDelegate.self
        case NowPlayingSceneDelegate.activityType:  configuration.delegateClass = NowPlayingSceneDelegate.self
        case HistorySceneDelegate.activityType:     configuration.delegateClass = HistorySceneDelegate.self
        default:                                    configuration.delegateClass = PodcastsSceneDelegate.self
        }
        return configuration
    }

    static func openSettingsWindow() {
        #if targetEnvironment(macCatalyst)
        activateOrCreate(delegateClass: SettingsSceneDelegate.self, activityType: SettingsSceneDelegate.activityType)
        #endif
    }

    static func openNowPlayingWindow() {
        #if targetEnvironment(macCatalyst)
        activateOrCreate(delegateClass: NowPlayingSceneDelegate.self, activityType: NowPlayingSceneDelegate.activityType)
        #endif
    }

    static func openHistoryWindow() {
        #if targetEnvironment(macCatalyst)
        activateOrCreate(delegateClass: HistorySceneDelegate.self, activityType: HistorySceneDelegate.activityType)
        #endif
    }

    private static func activateOrCreate(delegateClass: AnyClass, activityType: String) {
        let app = UIApplication.shared
        if let existing = app.openSessions.first(where: { $0.configuration.delegateClass == delegateClass }) {
            app.requestSceneSessionActivation(existing, userActivity: nil, options: nil, errorHandler: nil)
            return
        }
        let activity = NSUserActivity(activityType: activityType)
        activity.isEligibleForHandoff = false
        app.requestSceneSessionActivation(nil, userActivity: activity, options: nil, errorHandler: nil)
    }

    func applicationWillTerminate(_ application: UIApplication) {
        DiagnosticsCenter.shared.markCleanExit(reason: "applicationWillTerminate")
        eventLogger.closeSession(endPosition: player.elapsed)
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DiagnosticsCenter.shared.start()
        DiagnosticsCenter.shared.log("didFinishLaunching")
        registerBackgroundTasks()
        Self.configureBackgroundRefresh()
        EventLogger.shared = eventLogger
        eventLogger.observe(player)
        eventLogger.collapseOldEventsIfNeeded()
        registerPlaybackIntentHandlers()
        return true
    }

    #if targetEnvironment(macCatalyst)
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        let playPause = UIKeyCommand(
            title: "Play / Pause",
            action: #selector(menuPlayPause),
            input: " ",
            modifierFlags: []
        )
        let skipForward = UIKeyCommand(
            title: "Skip Forward 30s",
            action: #selector(menuSkipForward),
            input: UIKeyCommand.inputRightArrow,
            modifierFlags: .command
        )
        let skipBack = UIKeyCommand(
            title: "Skip Back 15s",
            action: #selector(menuSkipBack),
            input: UIKeyCommand.inputLeftArrow,
            modifierFlags: .command
        )
        let playbackMenu = UIMenu(
            title: "Playback",
            identifier: UIMenu.Identifier("com.nagel.podcasts.playback"),
            children: [playPause, skipForward, skipBack]
        )
        builder.insertSibling(playbackMenu, afterMenu: .view)

        let settingsCommand = UIKeyCommand(
            title: "Settings…",
            action: #selector(menuOpenSettings),
            input: ",",
            modifierFlags: .command
        )
        builder.replaceChildren(ofMenu: .application) { [settingsCommand] + $0 }

        let tab1 = UIKeyCommand(title: "Episodes", action: #selector(menuSelectTab1), input: "1", modifierFlags: .command)
        let tab2 = UIKeyCommand(title: "Podcasts",  action: #selector(menuSelectTab2), input: "2", modifierFlags: .command)
        let tab3 = UIKeyCommand(title: "Search",    action: #selector(menuSelectTab3), input: "3", modifierFlags: .command)
        let tabMenu = UIMenu(title: "Go", identifier: UIMenu.Identifier("com.nagel.podcasts.go"),
                            options: .displayInline, children: [tab1, tab2, tab3])
        builder.insertChild(tabMenu, atStartOfMenu: .view)
    }

    @objc private func menuOpenSettings() { Self.openSettingsWindow() }
    @objc private func menuPlayPause() { player.togglePlayPause() }
    @objc private func menuSkipForward() { player.seek(by: 30) }
    @objc private func menuSkipBack() { player.seek(by: -15) }

    @objc private func menuSelectTab1() { rootTabController()?.selectedIndex = 0 }
    @objc private func menuSelectTab2() { rootTabController()?.selectedIndex = 1 }
    @objc private func menuSelectTab3() { rootTabController()?.selectedIndex = 2 }

    private func rootTabController() -> RootTabController? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first?.rootViewController as? RootTabController }
            .first
    }
    #endif

    private func registerPlaybackIntentHandlers() {
        // Set the C callback closure — widget extension posts a Darwin notification after
        // writing a command to App Group UserDefaults; this wakes the app even when suspended.
        _widgetCommandCallback = { [weak self] in
            Task { @MainActor [weak self] in self?.executeWidgetCommand() }
        }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            widgetCommandCFCallback,
            AppGroupConstants.widgetCommandNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    func executeWidgetCommand() {
        let defaults = UserDefaults(suiteName: AppGroupConstants.identifier)
        guard let command = defaults?.string(forKey: AppGroupConstants.widgetCommandKey),
              let timestamp = defaults?.double(forKey: AppGroupConstants.widgetCommandTimeKey),
              Date().timeIntervalSince1970 - timestamp < 30
        else { return }
        defaults?.removeObject(forKey: AppGroupConstants.widgetCommandKey)
        defaults?.removeObject(forKey: AppGroupConstants.widgetCommandTimeKey)

        switch command {
        case "playpause":
            if player.currentEpisode != nil {
                player.togglePlayPause()
            } else {
                guard let episode = LibraryStore.lastPlaybackEpisode(in: modelContainer.mainContext) else { return }
                let position = LibraryStore.playbackPosition(for: episode, in: modelContainer.mainContext)
                let artworkURL = LibraryStore.localArtworkURL(for: episode, in: modelContainer.mainContext)
                player.play(episode, at: position, artworkURL: artworkURL)
            }
        default:
            if command.hasPrefix("skipforward:"), let secs = Double(command.dropFirst("skipforward:".count)) {
                player.seek(by: secs)
            } else if command.hasPrefix("skipback:"), let secs = Double(command.dropFirst("skipback:".count)) {
                player.seek(by: -secs)
            }
        }
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

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url, url.scheme == "podcatcher" else { return }
        (window?.rootViewController as? RootTabController)?.handle(deepLink: url)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Save proactively so SwiftData's willResignActive auto-save finds a clean context.
        let appDelegate = UIApplication.shared.delegate as? PodcastsAppDelegate
        (window?.rootViewController as? RootTabController)?.persistCurrentPlaybackState()
        try? appDelegate?.modelContainer.mainContext.save()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        DiagnosticsCenter.shared.log("sceneDidBecomeActive")
        let appDelegate = UIApplication.shared.delegate as? PodcastsAppDelegate
        appDelegate?.player.refreshSystemPlaybackIntegration()
        appDelegate?.executeWidgetCommand()
        let root = window?.rootViewController as? RootTabController
        root?.checkSleepRecovery()
        root?.flushLibrarySnapshot()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        DiagnosticsCenter.shared.log("sceneDidEnterBackground")
        PodcastsAppDelegate.configureBackgroundRefresh()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        DiagnosticsCenter.shared.markCleanExit(reason: "sceneDidDisconnect")
        let app = UIApplication.shared.delegate as? PodcastsAppDelegate
        app?.eventLogger.closeSession(endPosition: app?.player.elapsed ?? 0)
        (window?.rootViewController as? RootTabController)?.endLiveActivity()
    }
}

final class SettingsSceneDelegate: UIResponder, UIWindowSceneDelegate, UIDocumentPickerDelegate {
    static let activityType = "com.nagel.podcasts.settings"

    var window: UIWindow?
    private weak var settingsVC: AppSettingsViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene,
              let appDelegate = UIApplication.shared.delegate as? PodcastsAppDelegate else { return }

        let vc = AppSettingsViewController(
            modelContext: appDelegate.modelContainer.mainContext,
            client: BackendClient()
        )
        settingsVC = vc
        vc.importOPML = { [weak self, weak vc] in
            guard let self, let vc else { return }
            let picker = UIDocumentPickerViewController(
                forOpeningContentTypes: [.xml, UTType(filenameExtension: "opml") ?? .xml],
                asCopy: true
            )
            picker.delegate = self
            picker.allowsMultipleSelection = false
            vc.navigationController?.present(picker, animated: true)
        }

        let nav = UINavigationController(rootViewController: vc)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        self.window = window

        #if targetEnvironment(macCatalyst)
        windowScene.title = "Settings"
        if let titlebar = windowScene.titlebar {
            titlebar.titleVisibility = .visible
            titlebar.toolbar = nil
        }
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 480, height: 560)
        windowScene.sizeRestrictions?.maximumSize = CGSize(width: 640, height: 900)
        #endif
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let vc = settingsVC else { return }
        Task { await vc.importOPML(from: url) }
    }
}

final class NowPlayingSceneDelegate: UIResponder, UIWindowSceneDelegate {
    static let activityType = "com.nagel.podcasts.nowplaying"
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene,
              let appDelegate = UIApplication.shared.delegate as? PodcastsAppDelegate else { return }

        let vc = NowPlayingViewController(modelContext: appDelegate.modelContainer.mainContext, player: appDelegate.player)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        self.window = window

        #if targetEnvironment(macCatalyst)
        windowScene.title = "Now Playing"
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 420, height: 620)
        windowScene.sizeRestrictions?.maximumSize = CGSize(width: 560, height: 860)
        #endif
    }
}

final class HistorySceneDelegate: UIResponder, UIWindowSceneDelegate {
    static let activityType = "com.nagel.podcasts.history"
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene,
              let appDelegate = UIApplication.shared.delegate as? PodcastsAppDelegate else { return }

        let vc = HistoryViewController(modelContext: appDelegate.modelContainer.mainContext, player: appDelegate.player)
        let nav = UINavigationController(rootViewController: vc)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        self.window = window

        #if targetEnvironment(macCatalyst)
        windowScene.title = "History"
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 440, height: 500)
        windowScene.sizeRestrictions?.maximumSize = CGSize(width: 700, height: 1000)
        #endif
    }
}
