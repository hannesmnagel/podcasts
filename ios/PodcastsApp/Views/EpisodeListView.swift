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
    var mode: EpisodeListMode
    private let modelContext: ModelContext
    private let player: PlayerController
    private let client = BackendClient()
    private let libraryStoreActor: LibraryStoreActor
    private var episodes: [EpisodeDTO] = []
    var visibleEpisodeSnapshot: [EpisodeDTO] = []
    private var playedEpisodeIDs: Set<String> = []
    private var deletedEpisodeIDs: Set< String> = []
    private var downloadedEpisodeIDs: Set<String> = []
    private var summarySnippets: [String: String] = [:]
    private var artworkURLs: [String: URL] = [:]
    private let podcastHeaderView = PodcastDetailHeaderView()
    private var downloadProgressCancellable: AnyCancellable?
    private var navigationDownloadProgressCancellable: AnyCancellable?
    private var playerStateCancellable: AnyCancellable?
    private var hasDownloadButtonInNavigation = false
    private var isLoading = false
    private var isWaitingForInitialCrawl = false
    // In-podcast scoped search (only used in `.podcast` mode).
    private var inPodcastSearchQuery = ""
    private var inPodcastSearchTask: Task<Void, Never>?
    private var inPodcastServerHits: [String: EpisodeDTO] = [:]

    init(title: String, mode: EpisodeListMode, modelContext: ModelContext, player: PlayerController) {
        self.mode = mode
        self.modelContext = modelContext
        self.player = player
        self.libraryStoreActor = LibraryStoreActor(modelContainer: modelContext.container)
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
        tableView.allowsSelectionDuringEditing = true
        tableView.allowsMultipleSelection = true
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        tableView.dragInteractionEnabled = true
        configureNavigationItems()
        setupInPodcastSearchIfNeeded()
        bindDownloadProgressNavigationItem()
        bindPlayerState()
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
        (tabBarController as? RootTabController)?.setMiniPlayerSuppressed(isEditing, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
        tabBarController?.setTabBarHidden(false, animated: animated)
        (tabBarController as? RootTabController)?.setMiniPlayerSuppressed(false, animated: animated)
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
        let isCurrentPlaying = player.currentEpisode?.stableID == episode.stableID && player.isPlaying
        cell.configure(
            episode: episode,
            summaryText: summarySnippets[episode.stableID] ?? episode.summary,
            artworkURL: artworkURLs[episode.stableID],
            isPlayed: playedEpisodeIDs.contains(episode.stableID),
            dimsPlayed: showsPlayedEpisodes,
            isCurrentPlaying: isCurrentPlaying
        )
        if !inPodcastSearchQuery.isEmpty {
            applyInPodcastHighlight(to: cell, for: episode)
        }
        cell.playTapped = { [weak self] in self?.play(episode) }
        return cell
    }

    private func applyInPodcastHighlight(to cell: EpisodeCell, for episode: EpisodeDTO) {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let serverHit = inPodcastServerHits[episode.stableID]
        if let marked = serverHit?.matchSnippet, !marked.isEmpty {
            cell.applySearchHighlight(snippet: SearchHighlighter.attributed(markedSnippet: marked, font: font), matchField: serverHit?.matchField, date: episode.publishedAt)
            return
        }
        let folded = SearchIntelligence.fold(inPodcastSearchQuery)
        if SearchIntelligence.fold(episode.title).contains(folded) {
            cell.applySearchHighlight(snippet: nil, matchField: "title", date: episode.publishedAt)
        } else if let summary = episode.summary,
                  let snippet = SearchHighlighter.attributed(text: summary, matching: inPodcastSearchQuery, font: font) {
            cell.applySearchHighlight(snippet: snippet, matchField: "summary", date: episode.publishedAt)
        } else if let field = serverHit?.matchField {
            cell.applySearchHighlight(snippet: nil, matchField: field, date: episode.publishedAt)
        }
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
        refreshControl?.isEnabled = !editing
        navigationController?.setToolbarHidden(!editing, animated: animated)
        tabBarController?.setTabBarHidden(editing, animated: animated)
        (tabBarController as? RootTabController)?.setMiniPlayerSuppressed(editing, animated: animated)
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
                    await self.refreshStateCacheAndEpisodeSets()
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
        nil
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard !tableView.isEditing else { return nil }
        let episode = visibleEpisodeSnapshot[indexPath.row]
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            let isDownloaded = self.downloadedEpisodeIDs.contains(episode.stableID)
            var actions: [UIMenuElement] = [
                UIAction(title: "Play", image: UIImage(systemName: "play.fill")) { _ in self.play(episode) },
                UIAction(title: self.playedEpisodeIDs.contains(episode.stableID) ? "Mark as Unplayed" : "Mark as Played", image: UIImage(systemName: "checkmark.circle")) { _ in self.togglePlayed(episode) },
                UIAction(title: "Share Apple Podcasts Link", image: UIImage(systemName: "square.and.arrow.up")) { _ in self.shareApplePodcastsLink(for: episode, in: self.modelContext) }
            ]
            if self.downloadedAudioFileURL(for: episode, in: self.modelContext) != nil {
                actions.append(UIAction(title: "Share Audio File", image: UIImage(systemName: "waveform")) { _ in
                    self.shareDownloadedAudioFile(for: episode, in: self.modelContext)
                })
            }
            if isDownloaded {
                actions.append(UIAction(title: "Remove Download", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    LibraryStore.removeDownload(for: episode, in: self.modelContext)
                    self.downloadedEpisodeIDs.remove(episode.stableID)
                    self.tableView.reloadData()
                })
            } else {
                actions.append(UIAction(title: "Download Episode", image: UIImage(systemName: "arrow.down.circle")) { _ in
                    self.showProgressFooter(for: episode.stableID)
                    Task {
                        await LibraryStore.downloadAudio(for: episode, in: self.modelContext)
                        await self.refreshStateCacheAndEpisodeSets()
                        self.tableView.reloadData()
                    }
                })
            }
            actions.append(UIAction(title: "Hide Episode", image: UIImage(systemName: "eye.slash"), attributes: .destructive) { _ in
                LibraryStore.markDeleted(episode, in: self.modelContext)
                Task { [weak self] in
                    guard let self else { return }
                    await self.refreshEpisodeStateSets()
                    self.refreshVisibleEpisodeSnapshot()
                    self.tableView.reloadData()
                    self.updateEmptyState()
                }
            })
            return UIMenu(children: actions)
        })
    }

    func configureNavigationItems() {
        hasDownloadButtonInNavigation = hasVisibleDownloadProgress
        navigationItem.leftBarButtonItems = additionalLeftBarButtonItems()
        var items: [UIBarButtonItem] = []
        items.append(contentsOf: additionalRightBarButtonItems())
        if hasDownloadButtonInNavigation {
            items.append(UIBarButtonItem(image: UIImage(systemName: "arrow.down.circle.fill"), primaryAction: UIAction { [weak self] _ in
                self?.showDownloadsSheet()
            }))
            items.last?.accessibilityLabel = "Downloads"
        }
        if case .podcast = mode {
            let menuItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: podcastOptionsMenu())
            menuItem.accessibilityLabel = "Podcast Options"
            items.append(menuItem)
        }
        navigationItem.rightBarButtonItems = items.reversed()
    }

    func additionalRightBarButtonItems() -> [UIBarButtonItem] { [] }
    func additionalLeftBarButtonItems() -> [UIBarButtonItem] { [] }

    private var hasVisibleDownloadProgress: Bool {
        DownloadProgressCenter.shared.progresses.values.contains { !$0.isFinished }
    }

    private func bindDownloadProgressNavigationItem() {
        navigationDownloadProgressCancellable = DownloadProgressCenter.shared.$progresses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let shouldShowDownloadButton = self.hasVisibleDownloadProgress
                guard shouldShowDownloadButton != self.hasDownloadButtonInNavigation else { return }
                self.configureNavigationItems()
            }
    }

    private func bindPlayerState() {
        playerStateCancellable = player.$currentEpisode
            .combineLatest(player.$isPlaying)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.updateVisibleCellPlaybackIndicators()
            }
    }

    private func updateVisibleCellPlaybackIndicators() {
        for case let cell as EpisodeCell in tableView.visibleCells {
            guard let indexPath = tableView.indexPath(for: cell),
                  visibleEpisodeSnapshot.indices.contains(indexPath.row) else { continue }
            let episodeID = visibleEpisodeSnapshot[indexPath.row].stableID
            let isCurrentPlaying = player.currentEpisode?.stableID == episodeID && player.isPlaying
            cell.setIsCurrentPlaying(isCurrentPlaying)
        }
    }

    private func showDownloadsSheet() {
        let controller = UINavigationController(rootViewController: DownloadProgressListViewController())
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
        }
        present(controller, animated: true)
    }

    private func podcastOptionsMenu() -> UIMenu {
        let hasEpisodes = !visibleEpisodeSnapshot.isEmpty
        let hasDownloads = !downloadedEpisodeIDs.isEmpty
        let hasHiddenEpisodes = !deletedEpisodeIDs.isEmpty
        let episodeActionAttributes: UIMenuElement.Attributes = hasEpisodes ? [] : .disabled
        return UIMenu(children: [
            UIAction(title: "Share Apple Podcasts Link", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                guard let self, let subscription = self.subscription else { return }
                self.shareApplePodcastsLink(for: subscription)
            },
            UIAction(title: "Mark All Played", image: UIImage(systemName: "checkmark.circle"), attributes: episodeActionAttributes) { [weak self] _ in
                self?.markAllPlayed()
            },
            UIAction(title: "Mark All Unplayed", image: UIImage(systemName: "circle"), attributes: episodeActionAttributes) { [weak self] _ in
                self?.markAllUnplayed()
            },
            UIAction(title: "Download All Episodes", image: UIImage(systemName: "arrow.down.circle"), attributes: episodeActionAttributes) { [weak self] _ in
                self?.downloadAllVisible()
            },
            UIAction(title: "Remove All Downloads", image: UIImage(systemName: "trash"), attributes: hasDownloads ? .destructive : [.destructive, .disabled]) { [weak self] _ in
                self?.confirmRemoveAllDownloads()
            },
            UIAction(title: "Restore Hidden Episodes", image: UIImage(systemName: "arrow.uturn.backward"), attributes: hasHiddenEpisodes ? [] : .disabled) { [weak self] _ in
                self?.restoreDeletedEpisodes()
            },
            UIAction(title: "Download Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in
                self?.showPodcastDownloadSettings()
            },
            UIAction(title: "Unfollow Podcast", image: UIImage(systemName: "minus.circle"), attributes: .destructive) { [weak self] _ in
                self?.confirmUnfollowPodcast()
            }
        ])
    }

    private func configurePodcastHeaderIfNeeded() {
        guard case .podcast = mode else { return }
        podcastHeaderView.configure(subscription: subscription)
        podcastHeaderView.contentSizeDidChange = { [weak self] in self?.updatePodcastHeaderSize() }
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

    func reload(mode: EpisodeListMode) {
        self.mode = mode
        Task { await load() }
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
        isWaitingForInitialCrawl = visibleEpisodeSnapshot.isEmpty && isPodcastMode
        updateEmptyState()
        defer {
            isLoading = false
            isWaitingForInitialCrawl = false
            refreshControl?.endRefreshing()
            updateEmptyState()
        }

        let cached = await cachedEpisodes()
        if !cached.isEmpty {
            episodes = cached
            await refreshEpisodeStateSets()
            refreshVisibleEpisodeSnapshot()
            tableView.reloadData()
            updateSelectionToolbar()
        }

        do {
            await refreshPodcastMetadataIfNeeded()
            episodes = try await loadEpisodes()
            await refreshEpisodeStateSets()
            refreshVisibleEpisodeSnapshot()
            configurePodcastHeaderIfNeeded()
            tableView.reloadData()
            updateSelectionToolbar()
            configureNavigationItems()
            await applyDownloadPolicyIfNeeded()
        } catch BackendError.notFound where isPodcastMode {
            episodes = await libraryStoreActor.fetchLocalEpisodes(forPodcastIDs: podcastModeIDs)
            await refreshEpisodeStateSets()
            refreshVisibleEpisodeSnapshot()
            tableView.reloadData()
            updateSelectionToolbar()
        } catch BackendError.server(let status, _) where isPodcastMode && status == 502 {
            episodes = await libraryStoreActor.fetchLocalEpisodes(forPodcastIDs: podcastModeIDs)
            await refreshEpisodeStateSets()
            refreshVisibleEpisodeSnapshot()
            tableView.reloadData()
            updateSelectionToolbar()
        } catch {
            showError(error)
        }
    }

    private func loadEpisodes() async throws -> [EpisodeDTO] {
        switch mode {
        case .podcast(let podcastID):
            await client.requestPodcastCrawl(podcastID)
            do {
                let fetched = try await client.fetchAllEpisodes(for: podcastID)
                await libraryStoreActor.cacheEpisodes(fetched)
            } catch BackendError.notFound {
                // Newly added optimistic subscriptions can be opened before the
                // backend has created/crawled the feed. Show an empty detail
                // instead of an error; a later refresh will hydrate episodes.
            }
            return await libraryStoreActor.fetchLocalEpisodes(forPodcastIDs: [podcastID])
        case .subscriptions(let podcastIDs):
            return try await loadSubscriptions(podcastIDs)
        case .search(let query):
            let fetched = try await client.search(query).episodes
            await libraryStoreActor.cacheEpisodes(fetched)
            return await libraryStoreActor.fetchLocalEpisodes(matching: query)
        case .placeholder:
            return []
        }
    }

    private func loadSubscriptions(_ podcastIDs: [String]) async throws -> [EpisodeDTO] {
        try await withThrowingTaskGroup(of: (String, [EpisodeDTO]).self) { group in
            for podcastID in podcastIDs {
                group.addTask {
                    await self.client.requestPodcastCrawl(podcastID)
                    return (podcastID, try await self.client.fetchAllEpisodes(for: podcastID))
                }
            }
            for try await (_, podcastEpisodes) in group {
                await libraryStoreActor.cacheEpisodes(podcastEpisodes)
            }
            return await libraryStoreActor.fetchLibraryEpisodes(subscriptionIDs: podcastIDs)
        }
    }

    private func refreshPodcastMetadataIfNeeded() async {
        guard case .podcast = mode else { return }
        guard let podcasts = try? await client.fetchAllPodcasts() else { return }
        LibraryStore.updateExistingSubscriptions(with: podcasts, in: modelContext)
        configurePodcastHeaderIfNeeded()
    }

    private func cachedEpisodes() async -> [EpisodeDTO] {
        switch mode {
        case .podcast(let podcastID):
            return await libraryStoreActor.fetchLocalEpisodes(forPodcastIDs: [podcastID])
        case .subscriptions(let podcastIDs):
            return await libraryStoreActor.fetchLibraryEpisodes(subscriptionIDs: podcastIDs)
        case .search(let query):
            return await libraryStoreActor.fetchLocalEpisodes(matching: query)
        case .placeholder:
            return []
        }
    }

    private func refreshEpisodeStateSets() async {
        let data = await libraryStoreActor.fetchDisplayData(for: episodes)
        playedEpisodeIDs = data.playedIDs
        deletedEpisodeIDs = data.deletedIDs
        downloadedEpisodeIDs = data.downloadedIDs
        summarySnippets = data.summarySnippets
        artworkURLs = data.artworkURLs
    }

    private func refreshStateCacheAndEpisodeSets() async {
        await refreshEpisodeStateSets()
    }

    func refreshVisibleEpisodeSnapshot() {
        var snapshot = episodes.filter { !deletedEpisodeIDs.contains($0.stableID) && (showsPlayedEpisodes || !playedEpisodeIDs.contains($0.stableID)) }
        if !inPodcastSearchQuery.isEmpty {
            snapshot = filterAndRankForInPodcastSearch(snapshot)
        }
        visibleEpisodeSnapshot = snapshot
    }

    private func filterAndRankForInPodcastSearch(_ episodes: [EpisodeDTO]) -> [EpisodeDTO] {
        let folded = SearchIntelligence.fold(inPodcastSearchQuery)
        func rank(_ episode: EpisodeDTO) -> Int {
            if SearchIntelligence.fold(episode.title).contains(folded) { return 3 }
            if let summary = episode.summary, SearchIntelligence.fold(summary).contains(folded) { return 2 }
            if inPodcastServerHits[episode.stableID] != nil { return 1 }
            return 0
        }
        return episodes
            .filter { rank($0) > 0 }
            .sorted {
                let lhs = rank($0), rhs = rank($1)
                if lhs != rhs { return lhs > rhs }
                return ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
            }
    }

    private func play(_ episode: EpisodeDTO) {
        if player.currentEpisode?.stableID == episode.stableID {
            player.togglePlayPause()
        } else {
            if LibraryStore.downloadedEpisode(for: episode, in: self.modelContext) == nil {
                FloatingDownloadHUD.shared.show(progressID: episode.stableID, title: episode.title)
            }
            Task { [weak self] in
                guard let self else { return }
                guard let playableEpisode = await LibraryStore.playableDownloadedEpisode(for: episode, in: self.modelContext) else {
                    self.showDownloadFailed(for: episode)
                    return
                }
                let start = LibraryStore.playbackPosition(for: playableEpisode, in: self.modelContext)
                self.player.play(playableEpisode, at: start, artworkURL: LibraryStore.localArtworkURL(for: playableEpisode, in: self.modelContext))
                await self.refreshStateCacheAndEpisodeSets()
                self.tableView.reloadData()
            }
        }
    }

    private func showDownloadFailed(for episode: EpisodeDTO) {
        FloatingDownloadHUD.shared.showFailure(progressID: episode.stableID, title: episode.title)
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

        if isWaitingForInitialCrawl {
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.startAnimating()
            let title = UILabel()
            title.text = "Loading episodes…"
            title.font = .preferredFont(forTextStyle: .headline)
            title.textAlignment = .center
            title.adjustsFontForContentSizeCategory = true
            let detail = UILabel()
            detail.text = "The feed is being crawled. Pull to refresh in a moment."
            detail.font = .preferredFont(forTextStyle: .footnote)
            detail.textColor = .secondaryLabel
            detail.textAlignment = .center
            detail.numberOfLines = 0
            detail.adjustsFontForContentSizeCategory = true
            let stack = UIStackView(arrangedSubviews: [indicator, title, detail])
            stack.axis = .vertical
            stack.alignment = .center
            stack.spacing = 10
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 24, left: 32, bottom: 24, right: 32)
            tableView.backgroundView = stack
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
        play.accessibilityLabel = "Play Selected"
        play.isEnabled = count == 1
        let played = UIBarButtonItem(image: UIImage(systemName: "checkmark.circle"), style: .plain, target: self, action: #selector(markSelectedPlayed))
        played.accessibilityLabel = "Mark as Played"
        played.isEnabled = count > 0
        let unplayed = UIBarButtonItem(image: UIImage(systemName: "circle"), style: .plain, target: self, action: #selector(markSelectedUnplayed))
        unplayed.accessibilityLabel = "Mark as Unplayed"
        unplayed.isEnabled = count > 0
        let download = UIBarButtonItem(image: UIImage(systemName: "arrow.down.circle"), style: .plain, target: self, action: #selector(downloadSelected))
        download.accessibilityLabel = "Download"
        download.isEnabled = count > 0
        let removeDownload = UIBarButtonItem(image: UIImage(systemName: "trash"), style: .plain, target: self, action: #selector(removeSelectedDownloads))
        removeDownload.accessibilityLabel = "Remove Download"
        removeDownload.tintColor = .systemRed
        removeDownload.isEnabled = count > 0
        var items: [UIBarButtonItem] = [
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
        if isEditing {
            items.append(UIBarButtonItem(systemItem: .flexibleSpace))
            items.append(UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.setEditing(false, animated: true)
            }))
        }
        toolbarItems = items
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
        Task {
            for episode in episodes {
                await LibraryStore.downloadAudio(for: episode, in: modelContext)
                await Task.yield()
            }
            await refreshStateCacheAndEpisodeSets()
            tableView.reloadData()
            updateSelectionToolbar()
        }
    }

    @objc private func removeSelectedDownloads() {
        LibraryStore.removeDownloads(for: selectedEpisodes, in: modelContext)
        setEditing(false, animated: true)
        Task { [weak self] in
            guard let self else { return }
            await self.refreshEpisodeStateSets()
            self.tableView.reloadData()
            self.updateEmptyState()
        }
    }

    private func markAllPlayed() {
        LibraryStore.markAllPlayed(episodes, in: modelContext)
        Task { [weak self] in
            guard let self else { return }
            await self.refreshEpisodeStateSets()
            self.refreshVisibleEpisodeSnapshot()
            self.tableView.reloadData()
            self.updateEmptyState()
        }
    }

    private func markAllUnplayed() {
        LibraryStore.markAllUnplayed(episodes, in: modelContext)
        Task { [weak self] in
            guard let self else { return }
            await self.refreshEpisodeStateSets()
            self.refreshVisibleEpisodeSnapshot()
            self.tableView.reloadData()
            self.updateEmptyState()
        }
    }

    private func downloadAllVisible() {
        let targets = visibleEpisodeSnapshot
        Task {
            for episode in targets {
                await LibraryStore.downloadAudio(for: episode, in: modelContext, progressID: "policy-\(episode.stableID)")
                await Task.yield()
            }
            await refreshStateCacheAndEpisodeSets()
            tableView.reloadData()
        }
    }

    private func confirmRemoveAllDownloads() {
        let alert = UIAlertController(title: "Remove Downloads?", message: "This removes local audio files for this podcast. Episodes stay in your library.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            self?.removeAllDownloads()
        })
        present(alert, animated: true)
    }

    private func removeAllDownloads() {
        LibraryStore.removeDownloads(for: episodes, in: modelContext)
        Task { [weak self] in
            guard let self else { return }
            await self.refreshEpisodeStateSets()
            self.tableView.reloadData()
        }
    }

    private func restoreDeletedEpisodes() {
        guard case .podcast(let podcastID) = mode else { return }
        let restored = LibraryStore.restoreDeletedEpisodes(forPodcastID: podcastID, in: modelContext)
        Task { [weak self] in
            guard let self else { return }
            await self.refreshEpisodeStateSets()
            self.refreshVisibleEpisodeSnapshot()
            self.tableView.reloadData()
            self.updateEmptyState()
            let alert = UIAlertController(title: "Restored Episodes", message: restored == 1 ? "1 episode was restored." : "\(restored) episodes were restored.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(alert, animated: true)
        }
    }

    private func showPodcastDownloadSettings() {
        guard let subscription else { return }
        let controller = DownloadSettingsViewController(subscription: subscription)
        controller.policyDidChange = { [weak self] in
            Task { await self?.applyDownloadPolicyIfNeeded() }
        }
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
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
        _ = await LibraryStore.applyDownloadPolicy(to: episodes, subscription: subscription, in: modelContext)
        await refreshEpisodeStateSets()
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

    private func confirmUnfollowPodcast() {
        guard let subscription else { return }
        let title = subscription.title.isEmpty ? "this podcast" : subscription.title
        let alert = UIAlertController(title: "Unfollow Podcast?", message: "This removes \(title) and its saved episode data from your library.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Unfollow", style: .destructive) { [weak self] _ in
            self?.unfollowPodcast()
        })
        present(alert, animated: true)
    }

    private var isPodcastMode: Bool {
        if case .podcast = mode { return true }
        return false
    }

    private var podcastModeIDs: [String] {
        if case .podcast(let podcastID) = mode { return [podcastID] }
        return []
    }

    private var emptyText: String {
        if !inPodcastSearchQuery.isEmpty {
            return "No episodes in this show match “\(inPodcastSearchQuery)”."
        }
        switch mode {
        case .placeholder: return "This smart playlist is not wired yet."
        case .subscriptions(let ids) where ids.isEmpty: return "Search for podcasts and add them to your library."
        default: return "No crawled episodes yet."
        }
    }

    // MARK: - In-podcast scoped search

    private func setupInPodcastSearchIfNeeded() {
        guard case .podcast = mode else { return }
        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search this show (incl. transcripts)"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = true
    }

    private func runScopedSearch(_ trimmed: String) async {
        guard case .podcast(let podcastID) = mode else { return }
        guard let result = try? await client.search(trimmed, podcastID: podcastID) else { return }
        guard trimmed == inPodcastSearchQuery else { return }
        await libraryStoreActor.cacheEpisodes(result.episodes)
        inPodcastServerHits = Dictionary(result.episodes.map { ($0.stableID, $0) }, uniquingKeysWith: { first, _ in first })
        // The server may surface transcript-only episodes that aren't yet in the
        // locally loaded list; merge them so they can appear in results.
        let knownIDs = Set(episodes.map(\.stableID))
        let extras = result.episodes.filter { !knownIDs.contains($0.stableID) }
        if !extras.isEmpty { episodes.append(contentsOf: extras) }
        guard trimmed == inPodcastSearchQuery else { return }
        refreshVisibleEpisodeSnapshot()
        tableView.reloadData()
        updateEmptyState()
    }
}

extension EpisodeListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let trimmed = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != inPodcastSearchQuery else { return }
        inPodcastSearchQuery = trimmed
        inPodcastSearchTask?.cancel()

        if trimmed.isEmpty {
            inPodcastServerHits = [:]
            refreshVisibleEpisodeSnapshot()
            tableView.reloadData()
            updateEmptyState()
            return
        }

        // Instant local filter (title/description) while the network runs.
        refreshVisibleEpisodeSnapshot()
        tableView.reloadData()

        inPodcastSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.runScopedSearch(trimmed)
        }
    }
}

extension EpisodeListViewController: UITableViewDragDelegate, UITableViewDropDelegate {
    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard self is AllEpisodesViewController else { return [] }
        let episode = visibleEpisodeSnapshot[indexPath.row]
        let provider = NSItemProvider(object: episode.stableID as NSString)
        return [UIDragItem(itemProvider: provider)]
    }

    func tableView(_ tableView: UITableView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UITableViewDropProposal {
        guard session.localDragSession != nil else { return UITableViewDropProposal(operation: .cancel) }
        return UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard let destinationIndexPath = coordinator.destinationIndexPath,
              let item = coordinator.items.first,
              let sourceIndexPath = item.sourceIndexPath else { return }
        tableView.performBatchUpdates {
            let moved = visibleEpisodeSnapshot.remove(at: sourceIndexPath.row)
            visibleEpisodeSnapshot.insert(moved, at: destinationIndexPath.row)
            // Mirror into episodes array to keep consistent state
            if let srcEpisodeIdx = episodes.firstIndex(where: { $0.stableID == moved.stableID }) {
                episodes.remove(at: srcEpisodeIdx)
                // Insert at equivalent position in full array
                let anchorID = destinationIndexPath.row < visibleEpisodeSnapshot.count - 1
                    ? visibleEpisodeSnapshot[destinationIndexPath.row + 1].stableID : nil
                if let anchorID, let anchorIdx = episodes.firstIndex(where: { $0.stableID == anchorID }) {
                    episodes.insert(moved, at: anchorIdx)
                } else {
                    episodes.append(moved)
                }
            }
            tableView.moveRow(at: sourceIndexPath, to: destinationIndexPath)
        }
        coordinator.drop(item.dragItem, toRowAt: destinationIndexPath)
        LibraryStore.setEpisodeOrder(visibleEpisodeSnapshot.map(\.stableID), in: modelContext)
        configureNavigationItems()
    }
}

final class PodcastDetailHeaderView: UIView {
    private let cardView = UIView()
    private let artworkView = ArtworkImageView(cornerRadius: 16)
    private let titleLabel = UILabel()
    private let feedLabel = UILabel()
    private let descriptionContainer = UIView()
    private var lastConfiguredDescription: String?
    var contentSizeDidChange: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(subscription: PodcastSubscription?) {
        titleLabel.text = subscription?.title.isEmpty == false ? subscription?.title : "Podcast"
        feedLabel.text = subscription?.feedURL.host() ?? subscription?.feedURL.absoluteString
        artworkView.load(url: subscription?.artworkURL)
        let description = subscription?.podcastDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard description != lastConfiguredDescription else { return }
        lastConfiguredDescription = description
        descriptionContainer.subviews.forEach { $0.removeFromSuperview() }
        let descriptionView: UIView = description.isEmpty
            ? ShowNotesText.label(html: "No podcast description saved yet.", font: .preferredFont(forTextStyle: .body))
            : ShowNotesText.collapsibleView(raw: description, textColor: .label, secondaryColor: .secondaryLabel) { [weak self] in
                self?.contentSizeDidChange?()
            }
        descriptionView.translatesAutoresizingMaskIntoConstraints = false
        descriptionContainer.addSubview(descriptionView)
        NSLayoutConstraint.activate([
            descriptionView.leadingAnchor.constraint(equalTo: descriptionContainer.leadingAnchor),
            descriptionView.trailingAnchor.constraint(equalTo: descriptionContainer.trailingAnchor),
            descriptionView.topAnchor.constraint(equalTo: descriptionContainer.topAnchor),
            descriptionView.bottomAnchor.constraint(equalTo: descriptionContainer.bottomAnchor)
        ])
    }

    private func configure() {
        backgroundColor = .clear
        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .secondarySystemBackground
        cardView.layer.cornerRadius = 22
        cardView.clipsToBounds = true
        addSubview(cardView)

        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontForContentSizeCategory = true
        feedLabel.font = .preferredFont(forTextStyle: .subheadline)
        feedLabel.textColor = .secondaryLabel
        feedLabel.numberOfLines = 1
        let labels = UIStackView(arrangedSubviews: [titleLabel, feedLabel])
        labels.axis = .vertical
        labels.spacing = 3
        let topRow = UIStackView(arrangedSubviews: [artworkView, labels])
        topRow.axis = .horizontal
        topRow.alignment = .top
        topRow.spacing = 12

        let stack = UIStackView(arrangedSubviews: [topRow, descriptionContainer])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 14
        cardView.addSubview(stack)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            cardView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            stack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -14),
            artworkView.widthAnchor.constraint(equalToConstant: 88),
            artworkView.heightAnchor.constraint(equalToConstant: 88)
        ])
    }
}

final class EpisodeCell: UITableViewCell {
    static let reuseIdentifier = "EpisodeCell"

    private let artworkView = ArtworkImageView(cornerRadius: 8)
    private let titleLabel = UILabel()
    private let metadataLabel = UILabel()
    private let summaryLabel = UILabel()
    private let artworkOverlay = UIView()
    private let artworkTapButton = UIButton(type: .system)
    private let waveformView = WaveformBadgeView()
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
        artworkView.cancel()
        playTapped = nil
        waveformView.stopAnimating()
        summaryLabel.numberOfLines = 1
        summaryLabel.attributedText = nil
    }

    func configure(episode: EpisodeDTO, summaryText: String?, artworkURL: URL?, isPlayed: Bool, dimsPlayed: Bool, isCurrentPlaying: Bool) {
        episodeID = episode.stableID
        titleLabel.text = episode.title
        metadataLabel.text = episode.publishedAt?.formatted(date: .abbreviated, time: .omitted) ?? " "
        summaryLabel.numberOfLines = 1
        summaryLabel.attributedText = nil
        summaryLabel.text = summaryText?.isEmpty == false ? summaryText : " "
        artworkView.load(url: artworkURL)
        contentView.alpha = dimsPlayed && isPlayed ? 0.48 : 1
        setIsCurrentPlaying(isCurrentPlaying)
    }

    /// Overlays a search match: a highlighted snippet (sentence around the term)
    /// in place of the summary, plus a "Found in transcript/title" badge.
    func applySearchHighlight(snippet: NSAttributedString?, matchField: String?, date: Date?) {
        var metadataParts: [String] = []
        if let date { metadataParts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        switch matchField {
        case "transcript": metadataParts.append("Found in transcript")
        case "summary": metadataParts.append("Found in description")
        case "title": metadataParts.append("Title match")
        default: break
        }
        metadataLabel.text = metadataParts.isEmpty ? " " : metadataParts.joined(separator: "  ·  ")
        if let snippet {
            summaryLabel.numberOfLines = 2
            summaryLabel.attributedText = snippet
        }
    }

    private func configure() {
        accessoryType = .disclosureIndicator
        artworkView.isUserInteractionEnabled = true
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        metadataLabel.font = .preferredFont(forTextStyle: .caption1)
        metadataLabel.textColor = .secondaryLabel
        summaryLabel.font = .preferredFont(forTextStyle: .subheadline)
        summaryLabel.textColor = .secondaryLabel
        summaryLabel.numberOfLines = 1

        artworkOverlay.translatesAutoresizingMaskIntoConstraints = false
        artworkOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        artworkOverlay.layer.cornerRadius = 8
        artworkOverlay.isHidden = true
        artworkView.addSubview(artworkOverlay)

        artworkTapButton.translatesAutoresizingMaskIntoConstraints = false
        artworkTapButton.addTarget(self, action: #selector(play), for: .touchUpInside)
        artworkTapButton.accessibilityLabel = "Play or Pause"
        artworkView.addSubview(artworkTapButton)

        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.isHidden = true
        artworkView.addSubview(waveformView)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, metadataLabel, summaryLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        let row = UIStackView(arrangedSubviews: [artworkView, textStack])
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
            artworkOverlay.leadingAnchor.constraint(equalTo: artworkView.leadingAnchor),
            artworkOverlay.trailingAnchor.constraint(equalTo: artworkView.trailingAnchor),
            artworkOverlay.topAnchor.constraint(equalTo: artworkView.topAnchor),
            artworkOverlay.bottomAnchor.constraint(equalTo: artworkView.bottomAnchor),
            artworkTapButton.leadingAnchor.constraint(equalTo: artworkView.leadingAnchor),
            artworkTapButton.trailingAnchor.constraint(equalTo: artworkView.trailingAnchor),
            artworkTapButton.topAnchor.constraint(equalTo: artworkView.topAnchor),
            artworkTapButton.bottomAnchor.constraint(equalTo: artworkView.bottomAnchor),
            waveformView.centerXAnchor.constraint(equalTo: artworkView.centerXAnchor),
            waveformView.centerYAnchor.constraint(equalTo: artworkView.centerYAnchor),
            waveformView.widthAnchor.constraint(equalToConstant: 38),
            waveformView.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    func setIsCurrentPlaying(_ isCurrentPlaying: Bool) {
        artworkOverlay.isHidden = !isCurrentPlaying
        waveformView.isHidden = !isCurrentPlaying
        if isCurrentPlaying {
            waveformView.startAnimating()
        } else {
            waveformView.stopAnimating()
        }
    }

    @objc private func play() {
        playTapped?()
    }
}

final class WaveformBadgeView: UIView {
    private let bars: [UIView] = (0..<5).map { _ in UIView() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        bars.forEach { bar in
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.backgroundColor = .white
            bar.layer.cornerRadius = 1.5
            addSubview(bar)
        }

        let stack = UIStackView(arrangedSubviews: bars)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .fillEqually
        stack.spacing = 3
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        bars.forEach { $0.heightAnchor.constraint(equalToConstant: 6).isActive = true }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startAnimating() {
        for (idx, bar) in bars.enumerated() where bar.layer.animation(forKey: "wave") == nil {
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = 0.35
            animation.toValue = 1
            animation.duration = 0.45
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.beginTime = CACurrentMediaTime() + (Double(idx) * 0.08)
            bar.layer.add(animation, forKey: "wave")
        }
    }

    func stopAnimating() {
        bars.forEach { $0.layer.removeAnimation(forKey: "wave") }
    }
}

final class ArtworkImageView: UIImageView {
    private static let cache = NSCache<NSString, UIImage>()
    private static let defaultPlaceholderSize = CGSize(width: 96, height: 96)
    private var task: Task<Void, Never>?
    private var representedURL: URL?
    private var loadedURL: URL?
    private var loadedMinimumPixelDimension: CGFloat = 0
    private var isShowingPlaceholder = false
    private let placeholderLayer = CAShapeLayer()

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        contentMode = .scaleAspectFill
        clipsToBounds = true
        layer.cornerRadius = cornerRadius
        tintColor = .secondaryLabel
        placeholderLayer.fillColor = UIColor.secondaryLabel.withAlphaComponent(0.62).cgColor
        placeholderLayer.isHidden = true
        layer.addSublayer(placeholderLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(url: URL?, minimumPixelDimension: CGFloat = 160) {
        if url == nil {
            cancel()
            representedURL = nil
            loadedURL = nil
            loadedMinimumPixelDimension = minimumPixelDimension
            setPlaceholderImage()
            return
        }

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
        setPlaceholderImage()
        guard let url else { return }

        let cacheKey = Self.cacheKey(for: url, minimumPixelDimension: minimumPixelDimension)
        if let cached = Self.cache.object(forKey: cacheKey as NSString) {
            backgroundColor = nil
            isShowingPlaceholder = false
            placeholderLayer.isHidden = true
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
                self?.isShowingPlaceholder = false
                self?.placeholderLayer.isHidden = true
                self?.image = image
                self?.loadedURL = url
                self?.loadedMinimumPixelDimension = minimumPixelDimension
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if isShowingPlaceholder {
            setPlaceholderImage()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    nonisolated private static func loadImage(url: URL, targetSize: CGSize, scale: CGFloat, minimumPixelDimension: CGFloat) async -> CGImage? {
        let data: Data?
        if url.scheme == "data" {
            data = dataURLImageData(url)
        } else if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else if let cachedURL = await LocalMediaCache.existingCachedFileURL(for: url) {
            data = try? Data(contentsOf: cachedURL)
        } else if NetworkMonitor.shared.isOffline {
            data = nil
        } else if let cachedURL = try? await LocalMediaCache.cachedOrDownload(url) {
            data = try? Data(contentsOf: cachedURL)
        } else {
            data = nil
        }
        guard let data else { return nil }
        return downsample(data: data, targetSize: targetSize, scale: scale, minimumPixelDimension: minimumPixelDimension)
    }

    nonisolated private static func dataURLImageData(_ url: URL) -> Data? {
        let raw = url.absoluteString
        guard raw.hasPrefix("data:"),
              let comma = raw.firstIndex(of: ",") else {
            return nil
        }
        let metadata = raw[..<comma].lowercased()
        let payload = raw[raw.index(after: comma)...]
        if metadata.contains(";base64") {
            return Data(base64Encoded: String(payload))
        }
        return String(payload).removingPercentEncoding.flatMap { Data($0.utf8) }
    }

    nonisolated private static func downsample(data: Data, targetSize: CGSize, scale: CGFloat, minimumPixelDimension: CGFloat) -> CGImage? {
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

    nonisolated private static func cacheKey(for url: URL, minimumPixelDimension: CGFloat) -> String {
        "\(url.absoluteString)#\(Int(minimumPixelDimension.rounded(.up)))"
    }

    static func preload(url: URL?, targetSize: CGSize = CGSize(width: 370, height: 370), scale: CGFloat = 3, minimumPixelDimension: CGFloat = 1200) {
        guard let url else { return }
        let cacheKey = cacheKey(for: url, minimumPixelDimension: minimumPixelDimension)
        guard cache.object(forKey: cacheKey as NSString) == nil else { return }
        Task {
            guard let cgImage = await loadImage(url: url, targetSize: targetSize, scale: scale, minimumPixelDimension: minimumPixelDimension) else { return }
            cache.setObject(UIImage(cgImage: cgImage), forKey: cacheKey as NSString)
        }
    }

    private func setPlaceholderImage() {
        isShowingPlaceholder = true
        backgroundColor = .secondarySystemFill
        image = nil
        placeholderLayer.isHidden = false
        placeholderLayer.fillColor = UIColor.secondaryLabel.resolvedColor(with: traitCollection).withAlphaComponent(0.62).cgColor
        placeholderLayer.frame = bounds
        placeholderLayer.path = Self.placeholderPath(in: bounds.isEmpty ? CGRect(origin: .zero, size: Self.defaultPlaceholderSize) : bounds).cgPath
    }

    private static func placeholderPath(in bounds: CGRect) -> UIBezierPath {
        let size = bounds.size
        let path = UIBezierPath()
        let centerY = bounds.midY
        let base = min(size.width, size.height)
        let barWidth = base * 0.07
        let spacing = base * 0.08
        let heights = [0.22, 0.54, 0.94, 0.42, 0.74, 0.30].map { base * $0 }
        let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * spacing
        var x = bounds.minX + (size.width - totalWidth) / 2

        for height in heights {
            let rect = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
            path.append(UIBezierPath(roundedRect: rect, cornerRadius: barWidth / 2))
            x += barWidth + spacing
        }
        return path
    }
}

extension UIViewController {
    func showError(_ error: Error) {
        if isConnectivityError(error) { return }
        let alert = UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func isConnectivityError(_ error: Error) -> Bool {
        if let backendError = error as? BackendError {
            if case .offline = backendError {
                return true
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut:
                return true
            default:
                break
            }
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("no internet connection")
            || message.contains("network connection was lost")
            || message.contains("connection lost")
    }

    func share(_ url: URL?) {
        guard let url else { return }
        shareItems([url])
    }
}
