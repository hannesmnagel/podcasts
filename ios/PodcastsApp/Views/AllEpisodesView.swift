import SwiftData
import UIKit
import UniformTypeIdentifiers

final class AllEpisodesViewController: EpisodeListViewController, UIDocumentPickerDelegate {
    private let modelContext: ModelContext
    private let player: PlayerController
    private let client = BackendClient()
    private weak var activeAppSettingsController: AppSettingsViewController?

    init(modelContext: ModelContext, player: PlayerController) {
        self.modelContext = modelContext
        self.player = player
        super.init(title: "All Episodes", mode: .subscriptions(Self.subscriptionIDs(in: modelContext)), modelContext: modelContext, player: player)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload(mode: .subscriptions(Self.subscriptionIDs(in: modelContext)))
        configureNavigationItems()
    }

    override func refreshVisibleEpisodeSnapshot() {
        super.refreshVisibleEpisodeSnapshot()
        let indices = LibraryStore.episodeSortIndices(in: modelContext)
        guard !indices.isEmpty else { return }
        visibleEpisodeSnapshot.sort {
            let a = indices[$0.stableID] ?? Int.max
            let b = indices[$1.stableID] ?? Int.max
            if a == b { return ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            return a < b
        }
    }

    override func additionalRightBarButtonItems() -> [UIBarButtonItem] {
        let hasCustomOrder = !LibraryStore.episodeSortIndices(in: modelContext).isEmpty
        guard hasCustomOrder else { return [] }
        let reset = UIAction(title: "Reset to Date Order", image: UIImage(systemName: "arrow.counterclockwise"), attributes: .destructive) { [weak self] _ in
            guard let self else { return }
            LibraryStore.clearEpisodeOrder(in: self.modelContext)
            self.reload(mode: self.mode)
            self.configureNavigationItems()
        }
        let button = UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down.circle.fill"), menu: UIMenu(children: [reset]))
        button.tintColor = .systemOrange
        return [button]
    }

    override func additionalLeftBarButtonItems() -> [UIBarButtonItem] {
        [
            UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(showAppSettings)),
            UIBarButtonItem(image: UIImage(systemName: "clock"), style: .plain, target: self, action: #selector(showHistory))
        ]
    }

    @objc private func showHistory() {
        #if targetEnvironment(macCatalyst)
        PodcastsAppDelegate.openHistoryWindow()
        #else
        let controller = HistoryViewController(modelContext: modelContext, player: player)
        let nav = UINavigationController(rootViewController: controller)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
        }
        present(nav, animated: true)
        #endif
    }

    func openEpisode(_ episode: EpisodeDTO) {
        showEpisode(episode)
    }

    @objc private func showAppSettings() {
        #if targetEnvironment(macCatalyst)
        PodcastsAppDelegate.openSettingsWindow()
        #else
        let controller = AppSettingsViewController(modelContext: modelContext, client: client)
        controller.importOPML = { [weak self] in self?.showOPMLImporter() }
        controller.importDidFinish = { [weak self] in
            guard let self else { return }
            self.reload(mode: .subscriptions(Self.subscriptionIDs(in: self.modelContext)))
        }
        activeAppSettingsController = controller
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
        }
        present(navigation, animated: true)
        #endif
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


    private static func subscriptionIDs(in modelContext: ModelContext) -> [String] {
        var descriptor = FetchDescriptor<PodcastSubscription>(sortBy: [SortDescriptor(\.sortIndex)])
        descriptor.includePendingChanges = true
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.stableID)
    }
}
