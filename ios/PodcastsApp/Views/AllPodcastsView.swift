import SwiftData
import UIKit

final class AllPodcastsViewController: UITableViewController {
    private let modelContext: ModelContext
    private let player: PlayerController
    private var subscriptions: [PodcastSubscription] = []

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
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
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
        tableView.deselectRow(at: indexPath, animated: true)
        openPodcast(subscriptions[indexPath.row].stableID)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let subscription = subscriptions[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            guard let self else { return done(false) }
            self.modelContext.delete(subscription)
            self.load()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let subscription = subscriptions[indexPath.row]
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [
                UIAction(title: "Share Feed", image: UIImage(systemName: "square.and.arrow.up")) { _ in self.share(subscription.feedURL) },
                UIAction(title: "Delete Podcast", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    self.modelContext.delete(subscription)
                    self.load()
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
        subscriptions = (try? modelContext.fetch(descriptor)) ?? []
        tableView.reloadData()
        updateEmptyState()
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
