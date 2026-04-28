import SwiftData
import UIKit

final class AllEpisodesViewController: EpisodeListViewController {
    private let modelContext: ModelContext
    private let player: PlayerController

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
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .refresh, primaryAction: UIAction { [weak self] _ in
            self?.refreshFromSubscriptions()
        })
    }

    func openEpisode(_ episode: EpisodeDTO) {
        showEpisode(episode)
    }

    private func refreshFromSubscriptions() {
        let replacement = AllEpisodesViewController(modelContext: modelContext, player: player)
        navigationController?.setViewControllers([replacement], animated: false)
    }

    private static func subscriptionIDs(in modelContext: ModelContext) -> [String] {
        var descriptor = FetchDescriptor<PodcastSubscription>(sortBy: [SortDescriptor(\.sortIndex)])
        descriptor.includePendingChanges = true
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.stableID)
    }
}
