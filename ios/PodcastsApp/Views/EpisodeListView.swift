import Combine
import ImageIO
import SwiftData
import UIKit

enum EpisodeListMode {
    case podcast(String)
    case subscriptions([String])
    case search(String)
    case placeholder
}

class EpisodeListViewController: UITableViewController {
    private let mode: EpisodeListMode
    private let modelContext: ModelContext
    private let player: PlayerController
    private let client = BackendClient()
    private var episodes: [EpisodeDTO] = []
    private var visibleEpisodeSnapshot: [EpisodeDTO] = []
    private var playedEpisodeIDs: Set<String> = []
    private var deletedEpisodeIDs: Set< String> = []
    private var downloadedEpisodeIDs: Set<String> = []
    private let podcastHeaderView = PodcastDetailHeaderView()
    private var downloadProgressCancellable: AnyCancellable?
    private var isLoading = false

    init(title: String, mode: EpisodeListMode, modelContext: ModelContext, player: PlayerController) {
        self.mode = mode
        self.modelContext = modelContext
        self.player = player
        super.init(style: .plain)
        self.title = title.isEmpty ? "Episodes" : title
    }

    convenience init(title: String, podcastID: String, modelContext: ModelContext, player: PlayerController) {
        self.init(title: title, mode: .podcast(podcastID), modelContext: modelContext, player: player)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(EpisodeCell.self, forCellReuseIdentifier: EpisodeCell.reuseIdentifier)
        tableView.rowHeight = 112
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 100, bottom: 0, right: 0)
        tableView.allowsMultipleSelectionDuringEditing = true
        configureNavigationItems()
        configurePodcastHeaderIfNeeded()
        updateSelectionToolbar()
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        Task { await load() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(!isEditing, animated: animated)
        tabBarController?.setTabBarHidden(isEditing, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
        tabBarController?.setTabBarHidden(false, animated: animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePodcastHeaderSize()
    }

    @objc private func refresh() {
        Task { await load() }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        visibleEpisodeSnapshot.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: EpisodeCell.reuseIdentifier, for: indexPath) as! EpisodeCell
        let episode = visibleEpisodeSnapshot[indexPath.row]
        cell.configure(
            episode: episode,
            artworkURL: LibraryStore.localArtworkURL(for: episode, in: modelContext),
            isPlayed: playedEpisodeIDs.contains(episode.stableID),
            dimsPlayed: showsPlayedEpisodes,
            player: player
        )
        cell.playTapped = { [weak self] in self?.play(episode) }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !tableView.isEditing else {
            updateSelectionToolbar()
            return
        }
        tableView.deselectRow(at: indexPath, animated: true)
        showEpisode(visibleEpisodeSnapshot[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard tableView.isEditing else { return }
        updateSelectionToolbar()
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
        refreshControl?.isEnabled = !editing
        navigationController?.setToolbarHidden(!editing, animated: animated)
        tabBarController?.setTabBarHidden(editing, animated: animated)
        updateSelectionToolbar()
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !tableView.isEditing else { return nil }
        let episode = visibleEpisodeSnapshot[indexPath.row]
        let isDownloaded = downloadedEpisodeIDs.contains(episode.stableID)
        let download = UIContextualAction(style: isDownloaded ? .destructive : .normal, title: isDownloaded ? "Remove Download" : "Download") { [weak self] _, _, done in
            guard let self else { return done(false) }
            if isDownloaded {
                LibraryStore.removeDownload(for: episode, in: self.modelContext)
                self.downloadedEpisodeIDs.remove(episode.stableID)
                self.tableView.reloadData()
            } else {
                self.showProgressFooter(for: episode.stableID)
                Task {
                    await LibraryStore.downloadAudio(for: episode, in: self.modelContext)
                    self.refreshEpisodeStateSets()
                    self.tableView.reloadData()
                }
            }
            done(true)
        }
        download.backgroundColor = isDownloaded ? .systemRed : .systemBlue
        let playedTitle = playedEpisodeIDs.contains(episode.stableID) ? "Unplayed" : "Played"
        let played = UIContextualAction(style: .normal, title: playedTitle) { [weak self] _, _, done in
            self?.togglePlayed(episode)
            done(true)
        }
        played.backgroundColor = .systemGreen
        return UISwipeActionsConfiguration(actions: [download, played])
    }

    override func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !tableView.isEditing else { return nil }
        let episode = visibleEpisodeSnapshot[indexPath.row]
        let play = UIContextualAction(style: .normal, title: "Play") { [weak self] _, _, done in
            self?.play(episode)
            done(true)
        }
        play.backgroundColor = .systemOrange
        return UISwipeActionsConfiguration(actions: [play])
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard !tableView.isEditing else { return nil }
        let episode = visibleEpisodeSnapshot[indexPath.row]
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [
                UIAction(title: "Play", image: UIImage(systemName: "play.fill")) { _ in self.play(episode) },
                UIAction(title: self.playedEpisodeIDs.contains(episode.stableID) ? "Mark as Unplayed" : "Mark as Played", image: UIImage(systemName: "checkmark.circle")) { _ in self.togglePlayed(episode) },
                UIAction(title: "Share Episode Link", image: UIImage(systemName: "square.and.arrow.up")) { _ in self.share(URL(string: episode.audioURL)) },
                UIAction(title: "Download Episode", image: UIImage(systemName: "arrow.down.circle")) { _ in
                    self.showProgressFooter(for: episode.stableID)
                    Task {
                        await LibraryStore.downloadAudio(for: episode, in: self.modelContext)
                        self.refreshEpisodeStateSets()
                        self.tableView.reloadData()
                    }
                },
                UIAction(title: "Remove Download", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    LibraryStore.removeDownload(for: episode, in: self.modelContext)
                    self.downloadedEpisodeIDs.remove(episode.stableID)
                    self.tableView.reloadData()
                }
            ])
        })
    }

    private func configureNavigationItems() {
        switch mode {
        case .podcast:
            navigationItem.rightBarButtonItems = [editButtonItem, UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: podcastOptionsMenu())]
        default:
            navigationItem.rightBarButtonItem = editButtonItem
        }
    }

    private func podcastOptionsMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Mark All Played", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
                self?.markAllPlayed()
            },
            UIAction(title: "Mark All Unplayed", image: UIImage(systemName: "circle")) { [weak self] _ in
                self?.markAllUnplayed()
            },
            UIAction(title: "Download All Episodes", image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
                self?.downloadAllVisible()
            },
            UIAction(title: "Remove All Downloads", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.removeAllDownloads()
            },
            UIAction(title: "Restore Hidden Episodes", image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                self?.restoreDeletedEpisodes()
            },
            UIAction(title: "Download Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in
                self?.showPodcastDownloadSettings()
            },
            UIAction(title: "Unfollow Podcast", image: UIImage(systemName: "minus.circle"), attributes: .destructive) { [weak self] _ in
                self?.unfollowPodcast()
            }
        ])
    }

    private func configurePodcastHeaderIfNeeded() {
        guard case .podcast = mode else { return }
        podcastHeaderView.configure(subscription: subscription)
        podcastHeaderView.settingsTapped = { [weak self] in self?.showPodcastDownloadSettings() }
        podcastHeaderView.followTapped = { [weak self] in self?.unfollowPodcast() }
        podcastHeaderView.shareTapped = { [weak self] in self?.share(self?.subscription?.feedURL) }
        tableView.tableHeaderView = podcastHeaderView
        updatePodcastHeaderSize()
    }

    private func updatePodcastHeaderSize() {
        guard tableView.tableHeaderView === podcastHeaderView else { return }
        let width = tableView.bounds.width
        let size = podcastHeaderView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        guard podcastHeaderView.frame.width != width || abs(podcastHeaderView.frame.height - size.height) > 0.5 else { return }
        podcastHeaderView.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
        tableView.tableHeaderView = podcastHeaderView
    }

    func showEpisode(_ episode: EpisodeDTO) {
        navigationController?.pushViewController(EpisodeDetailViewController(episode: episode, modelContext: modelContext, player: player), animated: true)
    }

    private var showsPlayedEpisodes: Bool {
        if case .podcast = mode { return true }
        return false
    }

    private func load() async {
        guard !isLoading else {
            refreshControl?.endRefreshing()
            return
        }
        isLoading = true
        defer {
            isLoading = false
            refreshControl?.endRefreshing()
            updateEmptyState()
        }

        let cached = cachedEpisodes()
        if !cached.isEmpty {
            episodes = cached
            refreshEpisodeStateSets()
            refreshVisibleEpisodeSnapshot()
            tableView.reloadData()
            updateSelectionToolbar()
        }

        do {
            episodes = try await loadEpisodes()
            refreshEpisodeStateSets()
            refreshVisibleEpisodeSnapshot()
            configurePodcastHeaderIfNeeded()
            tableView.reloadData()
            updateSelectionToolbar()
            configureNavigationItems()
            await applyDownloadPolicyIfNeeded()
        } catch {
            showError(error)
        }
    }

    private func loadEpisodes() async throws -> [EpisodeDTO] {
        switch mode {
        case .podcast(let podcastID):
            let fetched = try await client.episodes(for: podcastID)
            await LibraryStore.cacheEpisodes(fetched, in: modelContext)
            return LibraryStore.localEpisodes(forPodcastIDs: [podcastID], in: modelContext)
        case .subscriptions(let podcastIDs):
            return try await loadSubscriptions(podcastIDs)
        case .search(let query):
            let fetched = try await client.search(query).episodes
            await LibraryStore.cacheEpisodes(fetched, in: modelContext)
            return LibraryStore.localEpisodes(matching: query, in: modelContext)
        case .placeholder:
            return []
        }
    }

    private func loadSubscriptions(_ podcastIDs: [String]) async throws -> [EpisodeDTO] {
        try await withThrowingTaskGroup(of: (String, [EpisodeDTO]).self) { group in
            for podcastID in podcastIDs {
                group.addTask { (podcastID, try await self.client.episodes(for: podcastID)) }
            }
            var fetched: [EpisodeDTO] = []
            for try await (_, podcastEpisodes) in group {
                await LibraryStore.cacheEpisodes(podcastEpisodes, in: modelContext)
                fetched += podcastEpisodes
            }
            return LibraryStore.localEpisodes(forPodcastIDs: podcastIDs, in: modelContext)
        }
    }

    private func cachedEpisodes() -> [EpisodeDTO] {
        switch mode {
        case .podcast(let podcastID):
            LibraryStore.localEpisodes(forPodcastIDs: [podcastID], in: modelContext)
        case .subscriptions(let podcastIDs):
            LibraryStore.localEpisodes(forPodcastIDs: podcastIDs, in: modelContext)
        case .search(let query):
            LibraryStore.localEpisodes(matching: query, in: modelContext)
        case .placeholder:
            []
        }
    }

    private func refreshEpisodeStateSets() {
        let sets = LibraryStore.episodeIDSets(for: episodes, in: modelContext)
        playedEpisodeIDs = sets.played
        deletedEpisodeIDs = sets.deleted
        downloadedEpisodeIDs = sets.downloaded
    }

    private func refreshVisibleEpisodeSnapshot() {
        visibleEpisodeSnapshot = episodes.filter { !deletedEpisodeIDs.contains($0.stableID) && (showsPlayedEpisodes || !playedEpisodeIDs.contains($0.stableID)) }
    }

    private func play(_ episode: EpisodeDTO) {
        if player.currentEpisode?.stableID == episode.stableID {
            player.togglePlayPause()
        } else {
            let start = LibraryStore.playbackPosition(for: episode, in: modelContext)
            player.play(episode, at: start, artworkURL: LibraryStore.localArtworkURL(for: episode, in: modelContext))
        }
    }

    private func togglePlayed(_ episode: EpisodeDTO) {
        if playedEpisodeIDs.contains(episode.stableID) {
            LibraryStore.markUnplayed(episode, in: modelContext)
            playedEpisodeIDs.remove(episode.stableID)
        } else {
            LibraryStore.markPlayed(episode, in: modelContext)
            playedEpisodeIDs.insert(episode.stableID)
        }
        refreshVisibleEpisodeSnapshot()
        tableView.reloadData()
        updateSelectionToolbar()
    }

    private func updateEmptyState() {
        guard visibleEpisodeSnapshot.isEmpty else {
            tableView.backgroundView = nil
            return
        }
        let label = UILabel()
        label.text = emptyText
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        tableView.backgroundView = label
    }

    private var selectedEpisodes: [EpisodeDTO] {
        (tableView.indexPathsForSelectedRows ?? [])
            .map(\.row)
            .filter { visibleEpisodeSnapshot.indices.contains($0) }
            .map { visibleEpisodeSnapshot[$0] }
    }

    private func updateSelectionToolbar() {
        let count = selectedEpisodes.count
        let play = UIBarButtonItem(image: UIImage(systemName: "play.fill"), style: .plain, target: self, action: #selector(playSelected))
        play.tintColor = .systemOrange
        play.isEnabled = count == 1
        let played = UIBarButtonItem(title: "Played", style: .plain, target: self, action: #selector(markSelectedPlayed))
        played.isEnabled = count > 0
        let unplayed = UIBarButtonItem(title: "Unplayed", style: .plain, target: self, action: #selector(markSelectedUnplayed))
        unplayed.isEnabled = count > 0
        let download = UIBarButtonItem(title: "Download", style: .plain, target: self, action: #selector(downloadSelected))
        download.isEnabled = count > 0
        let removeDownload = UIBarButtonItem(title: "Remove DL", style: .plain, target: self, action: #selector(removeSelectedDownloads))
        removeDownload.tintColor = .systemRed
        removeDownload.isEnabled = count > 0
        toolbarItems = [
            play,
            UIBarButtonItem(systemItem: .flexibleSpace),
            played,
            UIBarButtonItem(systemItem: .flexibleSpace),
            unplayed,
            UIBarButtonItem(systemItem: .flexibleSpace),
            download,
            UIBarButtonItem(systemItem: .flexibleSpace),
            removeDownload
        ]
    }

    @objc private func playSelected() {
        guard let episode = selectedEpisodes.first else { return }
        play(episode)
        setEditing(false, animated: true)
    }

    @objc private func markSelectedPlayed() {
        selectedEpisodes.forEach {
            LibraryStore.markPlayed($0, in: modelContext)
            playedEpisodeIDs.insert($0.stableID)
        }
        refreshVisibleEpisodeSnapshot()
        tableView.reloadData()
        updateSelectionToolbar()
    }

    @objc private func markSelectedUnplayed() {
        selectedEpisodes.forEach {
            LibraryStore.markUnplayed($0, in: modelContext)
            playedEpisodeIDs.remove($0.stableID)
        }
        refreshVisibleEpisodeSnapshot()
        tableView.reloadData()
        updateSelectionToolbar()
    }

    @objc private func downloadSelected() {
        let episodes = selectedEpisodes
        showProgressFooter(for: "selection")
        Task {
            for episode in episodes {
                await LibraryStore.downloadAudio(for: episode, in: modelContext, progressID: "selection")
                await Task.yield()
            }
            refreshEpisodeStateSets()
            tableView.reloadData()
            updateSelectionToolbar()
        }
    }

    @objc private func removeSelectedDownloads() {
        LibraryStore.removeDownloads(for: selectedEpisodes, in: modelContext)
        setEditing(false, animated: true)
        refreshEpisodeStateSets()
        tableView.reloadData()
        updateEmptyState()
    }

    private func markAllPlayed() {
        LibraryStore.markAllPlayed(episodes, in: modelContext)
        refreshEpisodeStateSets()
        refreshVisibleEpisodeSnapshot()
        tableView.reloadData()
        updateEmptyState()
    }

    private func markAllUnplayed() {
        LibraryStore.markAllUnplayed(episodes, in: modelContext)
        refreshEpisodeStateSets()
        refreshVisibleEpisodeSnapshot()
        tableView.reloadData()
        updateEmptyState()
    }

    private func downloadAllVisible() {
        let targets = visibleEpisodeSnapshot
        showProgressFooter(for: "podcast-all")
        Task {
            for episode in targets {
                await LibraryStore.downloadAudio(for: episode, in: modelContext, progressID: "podcast-all")
                await Task.yield()
            }
            refreshEpisodeStateSets()
            tableView.reloadData()
        }
    }

    private func removeAllDownloads() {
        LibraryStore.removeDownloads(for: episodes, in: modelContext)
        refreshEpisodeStateSets()
        tableView.reloadData()
    }

    private func restoreDeletedEpisodes() {
        guard case .podcast(let podcastID) = mode else { return }
        let restored = LibraryStore.restoreDeletedEpisodes(forPodcastID: podcastID, in: modelContext)
        refreshEpisodeStateSets()
        refreshVisibleEpisodeSnapshot()
        tableView.reloadData()
        updateEmptyState()

        let alert = UIAlertController(title: "Restored Episodes", message: restored == 1 ? "1 episode was restored." : "\(restored) episodes were restored.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func showPodcastDownloadSettings() {
        guard let subscription else { return }
        let controller = DownloadSettingsViewController(subscription: subscription)
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
        }
        present(controller, animated: true)
    }

    private var subscription: PodcastSubscription? {
        guard case .podcast(let podcastID) = mode else { return nil }
        let descriptor = FetchDescriptor<PodcastSubscription>(predicate: #Predicate { $0.stableID == podcastID })
        return try? modelContext.fetch(descriptor).first
    }

    private func applyDownloadPolicyIfNeeded() async {
        guard case .podcast = mode else { return }
        let policy = DownloadSettings.policy(for: subscription)
        let targets: [EpisodeDTO]
        switch policy {
        case .manual:
            return
        case .latest:
            targets = Array(visibleEpisodeSnapshot.prefix(1))
        case .unplayed:
            targets = visibleEpisodeSnapshot.filter { !playedEpisodeIDs.contains($0.stableID) }
        case .all:
            targets = visibleEpisodeSnapshot
        }

        for episode in targets where !downloadedEpisodeIDs.contains(episode.stableID) {
            await LibraryStore.downloadAudio(for: episode, in: modelContext, progressID: "policy-\(episode.stableID)")
            await Task.yield()
        }
        refreshEpisodeStateSets()
        tableView.reloadData()
    }

    private func showProgressFooter(for progressID: String) {
        let label = UILabel()
        label.text = "Downloading..."
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 38)
        tableView.tableFooterView = label

        downloadProgressCancellable = DownloadProgressCenter.shared.$progresses
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak label] progresses in
                guard let self, let label, let progress = progresses[progressID] else { return }
                label.text = progress.isFinished ? "Download complete" : "Downloading \(progress.percentText)"
                if progress.isFinished {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        if self.tableView.tableFooterView === label {
                            self.tableView.tableFooterView = nil
                        }
                        DownloadProgressCenter.shared.clear(id: progressID)
                    }
                }
            }
    }

    private func unfollowPodcast() {
        guard let subscription else { return }
        LibraryStore.unsubscribe(subscription, in: modelContext)
        navigationController?.popViewController(animated: true)
    }

    private var emptyText: String {
        switch mode {
        case .placeholder: "This smart playlist is not wired yet."
        case .subscriptions(let ids) where ids.isEmpty: "Search for podcasts and add them to your library."
        default: "No crawled episodes yet."
        }
    }
}

final class PodcastDetailHeaderView: UIView {
    private let artworkView = ArtworkImageView(cornerRadius: 16)
    private let titleLabel = UILabel()
    private let feedLabel = UILabel()
    private let descriptionLabel = UILabel()
    private let followButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)

    var followTapped: (() -> Void)?
    var settingsTapped: (() -> Void)?
    var shareTapped: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(subscription: PodcastSubscription?) {
        titleLabel.text = subscription?.title.isEmpty == false ? subscription?.title : "Podcast"
        feedLabel.text = subscription?.feedURL.absoluteString
        let description = subscription?.podcastDescription
            .map(ShowNotesProcessor.plainText)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        descriptionLabel.text = description?.isEmpty == false ? description : "No podcast description saved yet."
        artworkView.load(url: subscription?.artworkURL)
    }

    private func configure() {
        backgroundColor = .systemBackground
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontForContentSizeCategory = true
        feedLabel.font = .preferredFont(forTextStyle: .footnote)
        feedLabel.textColor = .secondaryLabel
        feedLabel.numberOfLines = 1
        descriptionLabel.font = .preferredFont(forTextStyle: .body)
        descriptionLabel.textColor = .secondaryLabel
        descriptionLabel.numberOfLines = 0
        descriptionLabel.adjustsFontForContentSizeCategory = true

        configureHeaderButton(followButton, title: "Unfollow", image: "minus.circle", action: #selector(followAction))
        configureHeaderButton(settingsButton, title: "Settings", image: "gearshape", action: #selector(settingsAction))
        configureHeaderButton(shareButton, title: "Share", image: "square.and.arrow.up", action: #selector(shareAction))

        let labels = UIStackView(arrangedSubviews: [titleLabel, feedLabel])
        labels.axis = .vertical
        labels.spacing = 4
        let topRow = UIStackView(arrangedSubviews: [artworkView, labels])
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 14

        let buttons = UIStackView(arrangedSubviews: [settingsButton, shareButton, followButton])
        buttons.axis = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [topRow, descriptionLabel, buttons])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            artworkView.widthAnchor.constraint(equalToConstant: 96),
            artworkView.heightAnchor.constraint(equalToConstant: 96)
        ])
    }

    private func configureHeaderButton(_ button: UIButton, title: String, image: String, action: Selector) {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: image)
        configuration.imagePadding = 6
        button.configuration = configuration
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    @objc private func followAction() {
        followTapped?()
    }

    @objc private func settingsAction() {
        settingsTapped?()
    }

    @objc private func shareAction() {
        shareTapped?()
    }
}

final class EpisodeCell: UITableViewCell {
    static let reuseIdentifier = "EpisodeCell"

    private let artworkView = ArtworkImageView(cornerRadius: 8)
    private let titleLabel = UILabel()
    private let metadataLabel = UILabel()
    private let summaryLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private var cancellables: Set<AnyCancellable> = []
    private var episodeID: String?
    var playTapped: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancellables.removeAll()
        artworkView.cancel()
        playTapped = nil
    }

    func configure(episode: EpisodeDTO, artworkURL: URL?, isPlayed: Bool, dimsPlayed: Bool, player: PlayerController) {
        episodeID = episode.stableID
        titleLabel.text = episode.title
        metadataLabel.text = episode.publishedAt?.formatted(date: .abbreviated, time: .omitted) ?? " "
        summaryLabel.text = episode.summary?.isEmpty == false ? episode.summary : " "
        artworkView.load(url: artworkURL)
        contentView.alpha = dimsPlayed && isPlayed ? 0.48 : 1
        updatePlayButton(player: player)
        player.$currentEpisode.combineLatest(player.$isPlaying)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak player] _, _ in
                guard let player else { return }
                self?.updatePlayButton(player: player)
            }
            .store(in: &cancellables)
    }

    private func configure() {
        accessoryType = .disclosureIndicator
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        metadataLabel.font = .preferredFont(forTextStyle: .caption1)
        metadataLabel.textColor = .secondaryLabel
        summaryLabel.font = .preferredFont(forTextStyle: .subheadline)
        summaryLabel.textColor = .secondaryLabel
        summaryLabel.numberOfLines = 1

        playButton.tintColor = .systemOrange
        playButton.addTarget(self, action: #selector(play), for: .touchUpInside)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, metadataLabel, summaryLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        let row = UIStackView(arrangedSubviews: [artworkView, textStack, playButton])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.alignment = .center
        row.spacing = 12
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            artworkView.widthAnchor.constraint(equalToConstant: 72),
            artworkView.heightAnchor.constraint(equalToConstant: 72),
            playButton.widthAnchor.constraint(equalToConstant: 44),
            playButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func updatePlayButton(player: PlayerController) {
        let isCurrentPlaying = player.currentEpisode?.stableID == episodeID && player.isPlaying
        playButton.setImage(UIImage(systemName: isCurrentPlaying ? "pause.circle.fill" : "play.circle.fill"), for: .normal)
        playButton.accessibilityLabel = isCurrentPlaying ? "Pause" : "Play"
    }

    @objc private func play() {
        playTapped?()
    }
}

final class ArtworkImageView: UIImageView {
    private static let cache = NSCache<NSString, UIImage>()
    private var task: Task<Void, Never>?
    private var representedURL: URL?
    private var loadedURL: URL?
    private var loadedMinimumPixelDimension: CGFloat = 0

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        contentMode = .scaleAspectFill
        clipsToBounds = true
        layer.cornerRadius = cornerRadius
        tintColor = .secondaryLabel
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(url: URL?, minimumPixelDimension: CGFloat = 160) {
        if loadedURL == url,
           loadedMinimumPixelDimension >= minimumPixelDimension {
            return
        }
        if representedURL == url,
           loadedMinimumPixelDimension >= minimumPixelDimension,
           task != nil {
            return
        }
        cancel()
        representedURL = url
        loadedURL = nil
        loadedMinimumPixelDimension = minimumPixelDimension
        image = UIImage(systemName: "waveform")
        backgroundColor = .secondarySystemFill
        guard let url else { return }

        let cacheKey = Self.cacheKey(for: url, minimumPixelDimension: minimumPixelDimension)
        if let cached = Self.cache.object(forKey: cacheKey as NSString) {
            backgroundColor = nil
            image = cached
            loadedURL = url
            loadedMinimumPixelDimension = minimumPixelDimension
            return
        }

        let targetSize = bounds.size == .zero ? CGSize(width: 96, height: 96) : bounds.size
        let scale = traitCollection.displayScale
        task = Task.detached(priority: .utility) { [weak self] in
            guard let cgImage = await Self.loadImage(url: url, targetSize: targetSize, scale: scale, minimumPixelDimension: minimumPixelDimension) else { return }
            await MainActor.run {
                let image = UIImage(cgImage: cgImage)
                Self.cache.setObject(image, forKey: cacheKey as NSString)
                guard self?.representedURL == url else { return }
                self?.backgroundColor = nil
                self?.image = image
                self?.loadedURL = url
                self?.loadedMinimumPixelDimension = minimumPixelDimension
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private static func loadImage(url: URL, targetSize: CGSize, scale: CGFloat, minimumPixelDimension: CGFloat) async -> CGImage? {
        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            data = try? await URLSession.shared.data(from: url).0
        }
        guard let data else { return nil }
        return downsample(data: data, targetSize: targetSize, scale: scale, minimumPixelDimension: minimumPixelDimension)
    }

    private static func downsample(data: Data, targetSize: CGSize, scale: CGFloat, minimumPixelDimension: CGFloat) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let maxDimension = max(targetSize.width, targetSize.height) * scale
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(minimumPixelDimension), Int(maxDimension))
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }

    private static func cacheKey(for url: URL, minimumPixelDimension: CGFloat) -> String {
        "\(url.absoluteString)#\(Int(minimumPixelDimension.rounded(.up)))"
    }
}

extension UIViewController {
    func showError(_ error: Error) {
        let alert = UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    func share(_ url: URL?) {
        guard let url else { return }
        present(UIActivityViewController(activityItems: [url], applicationActivities: nil), animated: true)
    }
}
