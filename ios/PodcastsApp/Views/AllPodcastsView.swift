import SwiftData
import UIKit
import UniformTypeIdentifiers

final class AllPodcastsViewController: UITableViewController, UIDocumentPickerDelegate {
    private let modelContext: ModelContext
    private let player: PlayerController
    private let client = BackendClient()
    private var subscriptions: [PodcastSubscription] = []
    private weak var activeAppSettingsController: AppSettingsViewController?
    private var isRefreshingPodcastMetadata = false

    init(modelContext: ModelContext, player: PlayerController) {
        self.modelContext = modelContext
        self.player = player
        super.init(style: .plain)
        title = "Library"
        tabBarItem = UITabBarItem(title: "Podcasts", image: UIImage(systemName: "square.stack"), tag: 1)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(PodcastSubscriptionCell.self, forCellReuseIdentifier: PodcastSubscriptionCell.reuseIdentifier)
        tableView.rowHeight = 82
        tableView.allowsSelectionDuringEditing = true
        tableView.allowsMultipleSelection = true
        tableView.allowsMultipleSelectionDuringEditing = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(showAppSettings))
        updateSelectionToolbar()
        load()
        refreshPodcastMetadata()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
        refreshPodcastMetadata()
        navigationController?.setToolbarHidden(!isEditing, animated: animated)
        tabBarController?.setTabBarHidden(isEditing, animated: animated)
        (tabBarController as? RootTabController)?.setMiniPlayerSuppressed(isEditing, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
        tabBarController?.setTabBarHidden(false, animated: animated)
        (tabBarController as? RootTabController)?.setMiniPlayerSuppressed(false, animated: animated)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        subscriptions.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Your Podcasts"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: PodcastSubscriptionCell.reuseIdentifier, for: indexPath) as! PodcastSubscriptionCell
        cell.configure(subscription: subscriptions[indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !tableView.isEditing else {
            updateSelectionToolbar()
            return
        }
        tableView.deselectRow(at: indexPath, animated: true)
        openPodcast(subscriptions[indexPath.row].stableID)
    }

    override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard tableView.isEditing else { return }
        updateSelectionToolbar()
    }

    override func tableView(_ tableView: UITableView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        true
    }

    override func tableView(_ tableView: UITableView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
        setEditing(true, animated: true)
        tableView.selectRow(at: indexPath, animated: true, scrollPosition: .none)
        updateSelectionToolbar()
    }

    override func tableViewDidEndMultipleSelectionInteraction(_ tableView: UITableView) {
        updateSelectionToolbar()
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
        navigationController?.setToolbarHidden(!editing, animated: animated)
        tabBarController?.setTabBarHidden(editing, animated: animated)
        (tabBarController as? RootTabController)?.setMiniPlayerSuppressed(editing, animated: animated)
        updateSelectionToolbar()
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !tableView.isEditing else { return nil }
        let subscription = subscriptions[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "Unfollow") { [weak self] _, _, done in
            self?.confirmUnfollow(subscription)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard !tableView.isEditing else { return nil }
        let subscription = subscriptions[indexPath.row]
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [
                UIAction(title: "Share Apple Podcasts Link", image: UIImage(systemName: "square.and.arrow.up")) { _ in self.shareApplePodcastsLink(for: subscription) },
                UIAction(title: "Download Settings", image: UIImage(systemName: "gearshape")) { _ in self.showDownloadSettings(for: subscription) },
                UIAction(title: "Unfollow Podcast", image: UIImage(systemName: "minus.circle"), attributes: .destructive) { _ in
                    self.confirmUnfollow(subscription)
                }
            ])
        })
    }

    func openPodcast(_ podcastID: String) {
        load()
        let title = subscriptions.first { $0.stableID == podcastID }?.title ?? "Podcast"
        navigationController?.pushViewController(EpisodeListViewController(title: title, podcastID: podcastID, modelContext: modelContext, player: player), animated: true)
    }

    private func load() {
        var descriptor = FetchDescriptor<PodcastSubscription>(sortBy: [SortDescriptor(\.sortIndex)])
        descriptor.includePendingChanges = true
        subscriptions = Self.stablySortedSubscriptions((try? modelContext.fetch(descriptor)) ?? [])
        tableView.reloadData()
        updateEmptyState()
        updateSelectionToolbar()
    }

    private func refreshPodcastMetadata() {
        guard !isRefreshingPodcastMetadata else { return }
        isRefreshingPodcastMetadata = true
        let missingMetadataIDs = subscriptions
            .filter { $0.podcastDescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false || $0.artworkURL == nil }
            .map(\.stableID)
        Task {
            defer { isRefreshingPodcastMetadata = false }
            for podcastID in missingMetadataIDs {
                await client.requestPodcastCrawl(podcastID)
            }
            guard let podcasts = try? await client.fetchAllPodcasts() else { return }
            LibraryStore.updateExistingSubscriptions(with: podcasts, in: modelContext)
            load()
        }
    }

    private static func stablySortedSubscriptions(_ subscriptions: [PodcastSubscription]) -> [PodcastSubscription] {
        subscriptions.sorted { lhs, rhs in
            let lhsTitle = lhs.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhsTitle = rhs.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let lhsKey = lhsTitle.isEmpty ? lhs.feedURL.absoluteString : lhsTitle
            let rhsKey = rhsTitle.isEmpty ? rhs.feedURL.absoluteString : rhsTitle
            let titleComparison = lhsKey.localizedStandardCompare(rhsKey)
            if titleComparison != .orderedSame {
                return titleComparison == .orderedAscending
            }
            return lhs.stableID < rhs.stableID
        }
    }

    private func updateEmptyState() {
        guard subscriptions.isEmpty else {
            tableView.backgroundView = nil
            return
        }
        let label = UILabel()
        label.text = "No Podcasts\nAdd an RSS feed or search Apple Podcasts."
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        tableView.backgroundView = label
    }

    private var selectedSubscriptions: [PodcastSubscription] {
        (tableView.indexPathsForSelectedRows ?? [])
            .map(\.row)
            .filter { subscriptions.indices.contains($0) }
            .map { subscriptions[$0] }
    }

    private func updateSelectionToolbar() {
        let count = selectedSubscriptions.count
        let share = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), style: .plain, target: self, action: #selector(shareSelected))
        share.isEnabled = count > 0
        let label = UIBarButtonItem(title: count == 0 ? "Select Podcasts" : "\(count) Selected", style: .plain, target: nil, action: nil)
        label.isEnabled = false
        let delete = UIBarButtonItem(image: UIImage(systemName: "trash"), style: .plain, target: self, action: #selector(deleteSelected))
        delete.tintColor = .systemRed
        delete.isEnabled = count > 0
        var items: [UIBarButtonItem] = [share, UIBarButtonItem(systemItem: .flexibleSpace), label, UIBarButtonItem(systemItem: .flexibleSpace), delete]
        if isEditing {
            items.append(UIBarButtonItem(systemItem: .flexibleSpace))
            items.append(UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.setEditing(false, animated: true)
            }))
        }
        toolbarItems = items
    }

    @objc private func shareSelected() {
        let urls = selectedSubscriptions.map(\.feedURL)
        guard !urls.isEmpty else { return }
        present(UIActivityViewController(activityItems: urls, applicationActivities: nil), animated: true)
    }

    @objc private func deleteSelected() {
        let selected = selectedSubscriptions
        guard !selected.isEmpty else { return }
        selected.forEach { LibraryStore.unsubscribe($0, in: modelContext) }
        setEditing(false, animated: true)
        load()
    }

    @objc private func showAppSettings() {
        let controller = AppSettingsViewController(modelContext: modelContext, client: client)
        controller.importOPML = { [weak self] in self?.showOPMLImporter() }
        controller.importDidFinish = { [weak self] in self?.load() }
        activeAppSettingsController = controller
        let navigation = UINavigationController(rootViewController: controller)
        presentSettingsController(navigation)
    }

    private func showDownloadSettings(for subscription: PodcastSubscription) {
        presentDownloadSettings(subscription: subscription)
    }

    private func presentDownloadSettings(subscription: PodcastSubscription?) {
        let controller = DownloadSettingsViewController(subscription: subscription)
        controller.policyDidChange = { [weak self, weak subscription] in
            guard let self, let subscription else { return }
            Task { await self.applyDownloadPolicy(for: subscription) }
        }
        presentSettingsController(controller)
    }

    private func confirmUnfollow(_ subscription: PodcastSubscription) {
        let title = subscription.title.isEmpty ? "this podcast" : subscription.title
        let alert = UIAlertController(title: "Unfollow Podcast?", message: "This removes \(title) and its saved episode data from your library.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Unfollow", style: .destructive) { [weak self] _ in
            guard let self else { return }
            LibraryStore.unsubscribe(subscription, in: self.modelContext)
            self.load()
        })
        present(alert, animated: true)
    }

    private func applyDownloadPolicy(for subscription: PodcastSubscription) async {
        let episodes = LibraryStore.localEpisodes(forPodcastIDs: [subscription.stableID], in: modelContext)
        _ = await LibraryStore.applyDownloadPolicy(to: episodes, subscription: subscription, in: modelContext)
    }

    private func presentSettingsController(_ controller: UIViewController) {
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
        }
        present(controller, animated: true)
    }

    private func showOPMLImporter() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.xml, UTType(filenameExtension: "opml") ?? .xml], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presentedViewController?.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first,
              let settings = activeAppSettingsController else {
            return
        }
        Task {
            await settings.importOPML(from: url)
        }
    }
}

final class AppSettingsViewController: UITableViewController {
    private enum Row: Int, CaseIterable {
        case importOPML
        case globalDownloads
        case completedDownloads
        case backgroundDownloads
        case cellularDownloads
        case lowDataModeDownloads
        case preloadNextEpisode
        case applyDownloadPolicies
        case exportDiagnostics
        case chapterSkips
        case seekBack
        case seekForward
    }

    private let modelContext: ModelContext
    private let client: BackendClient
    private var statusText: String?
    var importOPML: (() -> Void)?
    var importDidFinish: (() -> Void)?

    init(modelContext: ModelContext, client: BackendClient) {
        self.modelContext = modelContext
        self.client = client
        super.init(style: .insetGrouped)
        title = "Settings"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? Row.allCases.count : (statusText == nil ? 0 : 1)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Podcast App" : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default
        guard indexPath.section == 0, let row = Row(rawValue: indexPath.row) else {
            var configuration = UIListContentConfiguration.subtitleCell()
            configuration.text = statusText
            configuration.secondaryText = nil
            cell.contentConfiguration = configuration
            cell.selectionStyle = .none
            return cell
        }

        var configuration = UIListContentConfiguration.subtitleCell()
        switch row {
        case .importOPML:
            configuration.text = "Import OPML"
            configuration.secondaryText = "Add subscriptions from an exported podcast list."
            cell.accessoryType = .disclosureIndicator
        case .globalDownloads:
            configuration.text = "Default Download Policy"
            configuration.secondaryText = DownloadSettings.globalPolicy.title
            cell.accessoryType = .disclosureIndicator
        case .completedDownloads:
            configuration.text = "Finished Downloads"
            configuration.secondaryText = DownloadSettings.completedCleanupPolicy.title
            cell.accessoryType = .disclosureIndicator
        case .backgroundDownloads:
            configuration.text = "Background Downloads"
            configuration.secondaryText = "Refresh feeds and apply download policies in the background."
            cell.accessoryView = makeSwitch(isOn: DownloadSettings.allowsBackgroundDownloads, action: #selector(backgroundDownloadsSwitchChanged(_:)))
            cell.selectionStyle = .none
        case .cellularDownloads:
            configuration.text = "Download Over Cellular"
            configuration.secondaryText = "Allow episode audio downloads on cellular or hotspot connections."
            cell.accessoryView = makeSwitch(isOn: DownloadSettings.allowsCellularDownloads, action: #selector(cellularDownloadsSwitchChanged(_:)))
            cell.selectionStyle = .none
        case .lowDataModeDownloads:
            configuration.text = "Low Data Mode Downloads"
            configuration.secondaryText = "Allow downloads when the current network is constrained."
            cell.accessoryView = makeSwitch(isOn: DownloadSettings.allowsLowDataModeDownloads, action: #selector(lowDataModeDownloadsSwitchChanged(_:)))
            cell.selectionStyle = .none
        case .preloadNextEpisode:
            configuration.text = "Preload Next Episode"
            configuration.secondaryText = "Start saving the next unplayed episode near the end of playback."
            cell.accessoryView = makeSwitch(isOn: DownloadSettings.preloadsNextEpisode, action: #selector(preloadNextEpisodeSwitchChanged(_:)))
            cell.selectionStyle = .none
        case .applyDownloadPolicies:
            configuration.text = "Apply Download Policies Now"
            configuration.secondaryText = "Download missing episodes for your current podcast policies."
            cell.accessoryType = .disclosureIndicator
        case .exportDiagnostics:
            configuration.text = "Export Diagnostics"
            configuration.secondaryText = "Share app logs and crash diagnostics from this device."
            cell.accessoryType = .disclosureIndicator
        case .chapterSkips:
            configuration.text = "Chapter Skip Rules"
            let count = ChapterSkipRuleStore.rules.count
            configuration.secondaryText = count == 1 ? "1 rule" : "\(count) rules"
            cell.accessoryType = .disclosureIndicator
        case .seekBack:
            configuration.text = "Back Skip"
            configuration.secondaryText = "\(Int(SeekSettings.backSeconds)) seconds"
            cell.accessoryView = makeStepper(value: SeekSettings.backSeconds, action: #selector(backStepperChanged(_:)))
        case .seekForward:
            configuration.text = "Forward Skip"
            configuration.secondaryText = "\(Int(SeekSettings.forwardSeconds)) seconds"
            cell.accessoryView = makeStepper(value: SeekSettings.forwardSeconds, action: #selector(forwardStepperChanged(_:)))
        }
        cell.contentConfiguration = configuration
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0, let row = Row(rawValue: indexPath.row) else { return }
        switch row {
        case .importOPML:
            importOPML?()
        case .globalDownloads:
            let controller = DownloadSettingsViewController(subscription: nil)
            controller.policyDidChange = { [weak self] in
                Task { await self?.applyDownloadPoliciesNow() }
            }
            navigationController?.pushViewController(controller, animated: true)
        case .completedDownloads:
            let controller = CompletedDownloadCleanupViewController()
            navigationController?.pushViewController(controller, animated: true)
        case .applyDownloadPolicies:
            Task { await applyDownloadPoliciesNow() }
        case .exportDiagnostics:
            Task { await exportDiagnostics() }
        case .backgroundDownloads, .cellularDownloads, .lowDataModeDownloads, .preloadNextEpisode:
            break
        case .chapterSkips:
            let controller = ChapterSkipRulesViewController()
            navigationController?.pushViewController(controller, animated: true)
        case .seekBack, .seekForward:
            break
        }
    }

    func importOPML(from url: URL) async {
        statusText = "Reading OPML..."
        tableView.reloadData()
        do {
            let imports = try await Self.readOPML(url: url)
            var added = 0
            for subscription in imports {
                statusText = "Importing \(added + 1) of \(imports.count)..."
                tableView.reloadData()
                let podcast = await client.hydratedPodcast(afterAdding: try await client.addPodcast(feedURL: subscription.feedURL))
                LibraryStore.subscribe(to: podcast, in: modelContext)
                added += 1
                await Task.yield()
            }
            statusText = added == 1 ? "Imported 1 podcast." : "Imported \(added) podcasts."
            importDidFinish?()
        } catch {
            statusText = "Import failed: \(error.localizedDescription)"
        }
        tableView.reloadData()
    }

    @concurrent
    private static func readOPML(url: URL) async throws -> [OPMLSubscription] {
        let data = try Data(contentsOf: url)
        return OPMLParser.subscriptions(from: data)
    }

    private func makeStepper(value: TimeInterval, action: Selector) -> UIStepper {
        let stepper = UIStepper()
        stepper.minimumValue = 5
        stepper.maximumValue = 120
        stepper.stepValue = 5
        stepper.value = value
        stepper.addTarget(self, action: action, for: .valueChanged)
        return stepper
    }

    private func makeSwitch(isOn: Bool, action: Selector) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addTarget(self, action: action, for: .valueChanged)
        return toggle
    }

    @objc private func backgroundDownloadsSwitchChanged(_ sender: UISwitch) {
        DownloadSettings.allowsBackgroundDownloads = sender.isOn
        PodcastsAppDelegate.configureBackgroundRefresh()
    }

    @objc private func cellularDownloadsSwitchChanged(_ sender: UISwitch) {
        DownloadSettings.allowsCellularDownloads = sender.isOn
    }

    @objc private func lowDataModeDownloadsSwitchChanged(_ sender: UISwitch) {
        DownloadSettings.allowsLowDataModeDownloads = sender.isOn
    }

    @objc private func preloadNextEpisodeSwitchChanged(_ sender: UISwitch) {
        DownloadSettings.preloadsNextEpisode = sender.isOn
    }

    private func applyDownloadPoliciesNow() async {
        statusText = "Applying download policies..."
        tableView.reloadData()
        var downloaded = 0
        let subscriptions = Self.subscriptions(in: modelContext)
        for subscription in subscriptions {
            let episodes = LibraryStore.localEpisodes(forPodcastIDs: [subscription.stableID], in: modelContext)
            downloaded += await LibraryStore.applyDownloadPolicy(to: episodes, subscription: subscription, in: modelContext)
            await Task.yield()
        }
        statusText = downloaded == 1 ? "Downloaded 1 episode." : "Downloaded \(downloaded) episodes."
        tableView.reloadData()
    }

    @MainActor
    private func exportDiagnostics() async {
        statusText = "Preparing diagnostics export..."
        tableView.reloadData()
        do {
            let exportURL = try await DiagnosticsCenter.shared.exportDiagnosticsBundle()
            statusText = "Diagnostics ready."
            tableView.reloadData()
            let activity = UIActivityViewController(activityItems: [exportURL], applicationActivities: nil)
            present(activity, animated: true)
        } catch {
            statusText = "Diagnostics export failed: \(error.localizedDescription)"
            tableView.reloadData()
        }
    }

    private static func subscriptions(in context: ModelContext) -> [PodcastSubscription] {
        var descriptor = FetchDescriptor<PodcastSubscription>(sortBy: [SortDescriptor(\.sortIndex)])
        descriptor.includePendingChanges = true
        return (try? context.fetch(descriptor)) ?? []
    }

    @objc private func backStepperChanged(_ sender: UIStepper) {
        SeekSettings.backSeconds = sender.value
        tableView.reloadRows(at: [IndexPath(row: Row.seekBack.rawValue, section: 0)], with: .none)
    }

    @objc private func forwardStepperChanged(_ sender: UIStepper) {
        SeekSettings.forwardSeconds = sender.value
        tableView.reloadRows(at: [IndexPath(row: Row.seekForward.rawValue, section: 0)], with: .none)
    }
}

final class CompletedDownloadCleanupViewController: UITableViewController {
    init() {
        super.init(style: .insetGrouped)
        title = "Finished Downloads"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        CompletedDownloadCleanupPolicy.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Delete completed episode downloads"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let policy = CompletedDownloadCleanupPolicy.allCases[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.text = policy.title
        configuration.secondaryText = policy.detail
        cell.contentConfiguration = configuration
        cell.accessoryType = DownloadSettings.completedCleanupPolicy == policy ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        DownloadSettings.completedCleanupPolicy = CompletedDownloadCleanupPolicy.allCases[indexPath.row]
        tableView.reloadData()
    }
}

final class DownloadSettingsViewController: UITableViewController {
    private let subscription: PodcastSubscription?
    var policyDidChange: (() -> Void)?

    init(subscription: PodcastSubscription?) {
        self.subscription = subscription
        super.init(style: .insetGrouped)
        title = subscription?.title ?? "Global Downloads"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        EpisodeDownloadPolicy.allCases.count + (subscription == nil ? 0 : 1)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        subscription == nil ? "Default for all podcasts" : "Download policy"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        if indexPath.row == 0, subscription != nil {
            var configuration = UIListContentConfiguration.subtitleCell()
            configuration.text = "Use Global"
            configuration.secondaryText = DownloadSettings.globalPolicy.title
            cell.contentConfiguration = configuration
            cell.accessoryType = subscription?.downloadPolicyRawValue == nil ? .checkmark : .none
            return cell
        }

        let offset = subscription == nil ? 0 : 1
        let policy = EpisodeDownloadPolicy.allCases[indexPath.row - offset]
        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.text = policy.title
        configuration.secondaryText = policy.detail
        cell.contentConfiguration = configuration
        let isSelected = subscription.map { $0.downloadPolicyRawValue == policy.rawValue } ?? (DownloadSettings.globalPolicy == policy)
        cell.accessoryType = isSelected ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.row == 0, let subscription {
            DownloadSettings.setPolicy(nil, for: subscription)
        } else {
            let offset = subscription == nil ? 0 : 1
            let policy = EpisodeDownloadPolicy.allCases[indexPath.row - offset]
            if let subscription {
                DownloadSettings.setPolicy(policy, for: subscription)
            } else {
                DownloadSettings.globalPolicy = policy
            }
        }
        tableView.reloadData()
        policyDidChange?()
    }
}

private final class PodcastSubscriptionCell: UITableViewCell {
    static let reuseIdentifier = "PodcastSubscriptionCell"
    private let artworkView = ArtworkImageView(cornerRadius: 8)
    private let titleLabel = UILabel()
    private let feedLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkView.cancel()
    }

    func configure(subscription: PodcastSubscription) {
        titleLabel.text = subscription.title.isEmpty ? subscription.feedURL.host() ?? "Podcast" : subscription.title
        feedLabel.text = subscription.feedURL.absoluteString
        artworkView.load(url: subscription.artworkURL)
    }

    private func configure() {
        accessoryType = .disclosureIndicator
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 2
        feedLabel.font = .preferredFont(forTextStyle: .subheadline)
        feedLabel.textColor = .secondaryLabel
        feedLabel.numberOfLines = 1

        let labels = UIStackView(arrangedSubviews: [titleLabel, feedLabel])
        labels.axis = .vertical
        labels.spacing = 4
        let row = UIStackView(arrangedSubviews: [artworkView, labels])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.alignment = .center
        row.spacing = 12
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            artworkView.widthAnchor.constraint(equalToConstant: 58),
            artworkView.heightAnchor.constraint(equalToConstant: 58)
        ])
    }
}
