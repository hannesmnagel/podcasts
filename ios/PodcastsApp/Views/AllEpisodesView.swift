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

    override func additionalRightBarButtonItems() -> [UIBarButtonItem] { [] }

    override func additionalLeftBarButtonItems() -> [UIBarButtonItem] {
        [UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(showAppSettings))]
    }

    func openEpisode(_ episode: EpisodeDTO) {
        showEpisode(episode)
    }

    @objc private func showAppSettings() {
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
