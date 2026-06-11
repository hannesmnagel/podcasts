import SwiftData
import UIKit

final class SearchViewController: UITableViewController, UISearchResultsUpdating, UISearchBarDelegate {
    private let crawlingProgressView = UIStackView()
    private let crawlingSpinner = UIActivityIndicatorView(style: .medium)
    private let crawlingLabel = UILabel()
    private let crawlingBackgroundView = UIView()
    private enum Row {
        case podcast(PodcastDTO)
        case directory(PodcastDirectoryDTO)
        case showMorePodcasts(Int)
        case episode(EpisodeDTO)
    }

    private enum PodcastSearchResult {
        case known(PodcastDTO)
        case directory(PodcastDirectoryDTO)

        var feedURL: String {
            switch self {
            case .known(let podcast): podcast.feedURL
            case .directory(let podcast): podcast.feedURL
            }
        }
    }

    private let modelContext: ModelContext
    private let player: PlayerController
    private let client = BackendClient()
    private var query = ""
    private var liveSearchTask: Task<Void, Never>?
    private var results = EpisodeSearchDTO()
    private var visibleEpisodeSnapshot: [EpisodeDTO] = []
    private var subscriptions: [PodcastSubscription] = []
    private var addingFeedURL: String? {
        didSet {
            updateCrawlingProgressVisibility()
        }
    }
    private var playedEpisodeIDs: Set<String> = []
    private var deletedEpisodeIDs: Set<String> = []
    private var summarySnippets: [String: String] = [:]
    private var podcastsCollapsed = false
    private var showAllPodcasts = false
    private var popularPodcasts: [PodcastDTO] = []
    /// Monotonic token so a slow in-flight search can't overwrite a newer one.
    private var searchGeneration = 0

    init(modelContext: ModelContext, player: PlayerController) {
        self.modelContext = modelContext
        self.player = player
        super.init(style: .plain)
        title = "Search"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(SearchPodcastCell.self, forCellReuseIdentifier: SearchPodcastCell.reuseIdentifier)
        tableView.register(EpisodeCell.self, forCellReuseIdentifier: EpisodeCell.reuseIdentifier)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 86

        setupCrawlingProgressView()

        #if targetEnvironment(macCatalyst)
        title = nil
        setupMacSearchHeader()
        #else
        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.searchBar.delegate = self
        searchController.searchBar.placeholder = "Search or add podcasts"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        #endif
        loadSubscriptions()
        updateRows()
        Task { await loadPopularPodcasts() }
    }

    private func loadPopularPodcasts() async {
        guard popularPodcasts.isEmpty else { return }
        guard let popular = try? await client.popularPodcasts(limit: 25), !popular.isEmpty else { return }
        popularPodcasts = popular
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateRows()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        #if targetEnvironment(macCatalyst)
        navigationController?.setNavigationBarHidden(true, animated: false)
        #endif
        loadSubscriptions()
        tableView.reloadData()
        Task { await loadPopularPodcasts() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if targetEnvironment(macCatalyst)
        macSearchField?.becomeFirstResponder()
        #endif
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        if query.isEmpty {
            liveSearchTask?.cancel()
            results = EpisodeSearchDTO()
            refreshVisibleEpisodeSnapshot()
            updateRows()
        } else {
            liveSearchTask?.cancel()
            liveSearchTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await submitSearch()
            }
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        liveSearchTask?.cancel()
        Task { await submitSearch() }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        2
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: nil
        case 1: visibleEpisodeSnapshot.isEmpty ? nil : "Episodes"
        default: nil
        }
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard section == 0, !podcastResults.isEmpty else { return nil }
        var configuration = UIButton.Configuration.plain()
        configuration.title = isShowingPopular ? "Popular Shows" : "Podcasts"
        configuration.image = UIImage(systemName: podcastsCollapsed ? "chevron.right" : "chevron.down")
        configuration.imagePlacement = .leading
        configuration.baseForegroundColor = .secondaryLabel
        let button = UIButton(type: .system)
        button.configuration = configuration
        button.contentHorizontalAlignment = .leading
        button.addTarget(self, action: #selector(togglePodcastsCollapsed), for: .touchUpInside)
        return button
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        section == 0 && !podcastResults.isEmpty ? 40 : UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: podcastsCollapsed ? 0 : visiblePodcastRowCount
        case 1: visibleEpisodeSnapshot.count
        default: 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.section {
        case 0:
            // Snapshot the computed results once; an interleaved async update
            // (search results, popular load) can otherwise change the count
            // between numberOfRows and cellForRow and make the index invalid.
            let visible = visiblePodcastResults
            if indexPath.row >= visible.count {
                let remaining = max(0, podcastResults.count - visible.count)
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                var configuration = UIListContentConfiguration.cell()
                configuration.text = "Show \(remaining) More Podcasts"
                configuration.image = UIImage(systemName: "chevron.down.circle")
                configuration.textProperties.color = .systemOrange
                cell.contentConfiguration = configuration
                return cell
            }

            let result = visible[indexPath.row]
            switch result {
            case .known(let podcast):
                let cell = tableView.dequeueReusableCell(withIdentifier: SearchPodcastCell.reuseIdentifier, for: indexPath) as! SearchPodcastCell
                let trimmedDescription = podcast.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                let subtitle = (trimmedDescription?.isEmpty == false ? trimmedDescription : nil) ?? URL(string: podcast.feedURL)?.host() ?? podcast.feedURL
                cell.configure(title: podcast.title.isEmpty ? podcast.feedURL : podcast.title, subtitle: subtitle, artworkURL: podcast.imageURL.flatMap(URL.init(string:)), isSubscribed: isSubscribed(to: podcast.stableID), isAdding: addingFeedURL == podcast.feedURL)
                cell.addTapped = { [weak self] in Task { await self?.addKnownPodcast(podcast) } }
                return cell
            case .directory(let podcast):
                let cell = tableView.dequeueReusableCell(withIdentifier: SearchPodcastCell.reuseIdentifier, for: indexPath) as! SearchPodcastCell
                cell.configure(title: podcast.title, subtitle: podcast.artistName ?? podcast.feedURL, artworkURL: podcast.artworkURL.flatMap(URL.init(string:)), isSubscribed: subscriptions.contains { $0.feedURL.absoluteString == podcast.feedURL }, isAdding: addingFeedURL == podcast.feedURL)
                cell.addTapped = { [weak self] in Task { await self?.addDirectoryPodcast(podcast) } }
                return cell
            }
        case 1:
            let episode = visibleEpisodeSnapshot[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: EpisodeCell.reuseIdentifier, for: indexPath) as! EpisodeCell
            let isCurrentPlaying = player.currentEpisode?.stableID == episode.stableID && player.isPlaying
            cell.configure(episode: episode, summaryText: summarySnippets[episode.stableID] ?? episode.summary, artworkURL: LibraryStore.localArtworkURL(for: episode, in: modelContext), isPlayed: playedEpisodeIDs.contains(episode.stableID), dimsPlayed: false, isCurrentPlaying: isCurrentPlaying)
            applySearchHighlight(to: cell, for: episode)
            cell.playTapped = { [weak self] in self?.play(episode) }
            return cell
        default:
            return UITableViewCell()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            let visible = visiblePodcastResults
            guard indexPath.row < visible.count else {
                if podcastResults.count > visible.count {
                    showAllPodcasts = true
                    tableView.reloadSections(IndexSet(integer: 0), with: .automatic)
                }
                return
            }
            openPreview(for: visible[indexPath.row])
            return
        }

        guard indexPath.section == 1, indexPath.row < visibleEpisodeSnapshot.count else { return }
        let episode = visibleEpisodeSnapshot[indexPath.row]
        pushDetail(EpisodeDetailViewController(episode: episode, modelContext: modelContext, player: player))
    }

    /// Pushes a detail screen. On Mac Catalyst the search tab keeps its
    /// navigation bar hidden (for the custom search header), which would leave
    /// pushed screens without a back button — so reveal it before pushing. It is
    /// hidden again when the search list reappears on pop (viewWillAppear).
    private func pushDetail(_ viewController: UIViewController) {
        #if targetEnvironment(macCatalyst)
        navigationController?.setNavigationBarHidden(false, animated: false)
        #endif
        navigationController?.pushViewController(viewController, animated: true)
    }

    private func openPreview(for result: PodcastSearchResult) {
        let identity: PodcastPreviewViewController.Identity
        switch result {
        case .known(let podcast): identity = .init(podcast: podcast)
        case .directory(let podcast): identity = .init(directory: podcast)
        }
        let preview = PodcastPreviewViewController(identity: identity, modelContext: modelContext, player: player)
        pushDetail(preview)
    }

    private func submitSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = rssFeedURL(from: trimmed) {
            await addFeedURL(url)
        } else {
            showAllPodcasts = false
            await search(trimmed)
        }
    }

    private func search(_ trimmed: String) async {
        guard !trimmed.isEmpty else { return }
        searchGeneration += 1
        let generation = searchGeneration

        // Instant, offline-friendly local results while the network search runs.
        let localMatches = LibraryStore.localEpisodes(matching: trimmed, in: modelContext)
        if !localMatches.isEmpty {
            let rankedLocal = await Self.rankEpisodes(localMatches, query: trimmed)
            guard generation == searchGeneration else { return }
            results = EpisodeSearchDTO(episodes: rankedLocal)
            refreshEpisodeStateSets()
            refreshVisibleEpisodeSnapshot()
            tableView.reloadData()
        }

        do {
            let searchResults = try await client.search(trimmed)
            guard generation == searchGeneration else { return }
            await LibraryStore.cacheEpisodes(searchResults.episodes, in: modelContext)
            guard generation == searchGeneration else { return }

            // Use the server hits directly so transcript-only matches (which the
            // local title/summary filter would drop) and their highlighted
            // snippets survive, then fold in any local-only matches.
            let merged = Self.mergeEpisodes(server: searchResults.episodes, local: localMatches)
            let ranked = await Self.rankEpisodes(merged, query: trimmed)
            guard generation == searchGeneration else { return }

            results = EpisodeSearchDTO(
                podcasts: searchResults.podcasts,
                episodes: ranked,
                directory: searchResults.directory
            )
            refreshEpisodeStateSets()
            refreshVisibleEpisodeSnapshot()
            updateRows()
        } catch {
            // A new keystroke cancels the in-flight request; that is not an error.
            if Self.isCancellation(error) { return }
            // Don't disrupt usable local results with an alert; only surface a
            // genuine failure when there is nothing to show.
            if visibleEpisodeSnapshot.isEmpty {
                showError(error)
            }
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private static func mergeEpisodes(server: [EpisodeDTO], local: [EpisodeDTO]) -> [EpisodeDTO] {
        var seen = Set(server.map(\.stableID))
        var output = server
        for episode in local where seen.insert(episode.stableID).inserted {
            output.append(episode)
        }
        return output
    }

    /// Ranks results so title matches beat description matches, which beat
    /// transcript-only matches, with an on-device semantic-similarity tiebreak.
    /// Runs off the main actor — embedding lookups are too heavy for the UI thread.
    private static func rankEpisodes(_ episodes: [EpisodeDTO], query: String) async -> [EpisodeDTO] {
        guard episodes.count > 1 else { return episodes }
        return await Task.detached(priority: .userInitiated) {
            let foldedQuery = SearchIntelligence.fold(query)
            let queryLemmas = Set(SearchIntelligence.lemmas(of: query))

            func score(_ episode: EpisodeDTO) -> Double {
                var score = 0.0
                let foldedTitle = SearchIntelligence.fold(episode.title)
                if foldedTitle.contains(foldedQuery) {
                    score += 1000
                } else if !queryLemmas.isEmpty,
                          !queryLemmas.isDisjoint(with: Set(SearchIntelligence.lemmas(of: episode.title))) {
                    score += 600
                }
                if let summary = episode.summary, SearchIntelligence.fold(summary).contains(foldedQuery) {
                    score += 200
                }
                switch episode.matchField {
                case "title": score += 300
                case "summary": score += 120
                case "transcript": score += 60
                default: break
                }
                score += SearchIntelligence.similarity(query: query, text: episode.title) * 120
                // Recency tiebreak (tiny, only separates otherwise-equal scores).
                score += (episode.publishedAt?.timeIntervalSince1970 ?? 0) / 1_000_000_000_000
                return score
            }

            return episodes
                .map { ($0, score($0)) }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
        }.value
    }

    private func addFeedURL(_ url: URL) async {
        addingFeedURL = url.absoluteString
        tableView.reloadData()
        defer {
            addingFeedURL = nil
            tableView.reloadData()
        }
        let placeholder = client.optimisticPodcast(feedURL: url)
        LibraryStore.subscribe(to: placeholder, in: modelContext)
        query = ""
        results = EpisodeSearchDTO()
        refreshVisibleEpisodeSnapshot()
        loadSubscriptions()
        updateRows()

        do {
            let added = try await client.addPodcast(feedURL: url)
            let podcast = await client.hydratedPodcast(afterAdding: added)
            LibraryStore.subscribe(to: podcast, in: modelContext)
            loadSubscriptions()
        } catch {
            // Keep the optimistic subscription visible. The backend may still be
            // creating/crawling the feed, and surfacing that transient 502 makes
            // the successful local add feel broken.
        }
    }

    private func addKnownPodcast(_ podcast: PodcastDTO) async {
        addingFeedURL = podcast.feedURL
        tableView.reloadData()
        LibraryStore.subscribe(to: podcast, in: modelContext)
        loadSubscriptions()
        LibraryStore.subscribe(to: await client.hydratedPodcast(afterAdding: podcast), in: modelContext)
        loadSubscriptions()
        addingFeedURL = nil
        tableView.reloadData()
    }

    private func addDirectoryPodcast(_ podcast: PodcastDirectoryDTO) async {
        guard let url = URL(string: podcast.feedURL) else { return }
        addingFeedURL = podcast.feedURL
        tableView.reloadData()
        defer {
            addingFeedURL = nil
            tableView.reloadData()
        }
        let placeholder = client.optimisticPodcast(feedURL: url, title: podcast.title, imageURL: podcast.artworkURL)
        LibraryStore.subscribe(to: placeholder, in: modelContext)
        loadSubscriptions()

        do {
            let added = try await client.addPodcast(feedURL: url)
            let addedPodcast = await client.hydratedPodcast(afterAdding: added).fillingMissingImageURL(podcast.artworkURL)
            LibraryStore.subscribe(to: addedPodcast, in: modelContext)
            loadSubscriptions()
            await search(query.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            // Keep the optimistic subscription visible; metadata will hydrate on
            // the next successful background refresh.
        }
    }



    private func updateRows() {
        tableView.reloadData()
        if podcastResults.isEmpty && visibleEpisodeSnapshot.isEmpty {
            tableView.backgroundView = makeEmptyState()
        } else {
            tableView.backgroundView = nil
        }
    }

    private func makeEmptyState() -> UIView {
        let container = UIView()
        let titleLabel = UILabel()
        titleLabel.text = query.isEmpty ? "Search Your Next Show" : "Nothing Found"
        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.textAlignment = .center

        let detailLabel = UILabel()
        detailLabel.text = query.isEmpty ? "Type a podcast name, topic, host, episode title, or paste an RSS feed URL." : "Try a broader podcast name, a host, a topic, or paste the feed URL directly."
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        let iconName = query.isEmpty ? "waveform.and.magnifyingglass" : "text.magnifyingglass"
        let icon = UIImageView(image: UIImage(systemName: iconName))
        icon.tintColor = .systemOrange
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, detailLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.layoutMargins = UIEdgeInsets(top: 0, left: 32, bottom: 0, right: 32)
        stack.isLayoutMarginsRelativeArrangement = true
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -40)
        ])
        return container
    }

    @objc private func togglePodcastsCollapsed() {
        podcastsCollapsed.toggle()
        tableView.reloadSections(IndexSet(integer: 0), with: .automatic)
    }

    private func loadSubscriptions() {
        subscriptions = (try? modelContext.fetch(FetchDescriptor<PodcastSubscription>())) ?? []
    }

    private func refreshEpisodeStateSets() {
        let sets = LibraryStore.episodeIDSets(for: results.episodes, in: modelContext)
        playedEpisodeIDs = sets.played
        deletedEpisodeIDs = sets.deleted
        summarySnippets = LibraryStore.summarySnippets(for: results.episodes, in: modelContext)
    }

    private func refreshVisibleEpisodeSnapshot() {
        visibleEpisodeSnapshot = results.episodes.filter { !deletedEpisodeIDs.contains($0.stableID) }
    }

    /// Shows the sentence around the match (with the term emphasized) and a
    /// "Found in transcript/description/title" badge on a search result cell.
    private func applySearchHighlight(to cell: EpisodeCell, for episode: EpisodeDTO) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let font = UIFont.preferredFont(forTextStyle: .subheadline)

        if let marked = episode.matchSnippet, !marked.isEmpty {
            let attributed = SearchHighlighter.attributed(markedSnippet: marked, font: font)
            cell.applySearchHighlight(snippet: attributed, matchField: episode.matchField, date: episode.publishedAt)
            return
        }

        let foldedQuery = SearchIntelligence.fold(trimmed)
        if SearchIntelligence.fold(episode.title).contains(foldedQuery) {
            cell.applySearchHighlight(snippet: nil, matchField: "title", date: episode.publishedAt)
        } else if let summary = episode.summary,
                  let snippet = SearchHighlighter.attributed(text: summary, matching: trimmed, font: font) {
            cell.applySearchHighlight(snippet: snippet, matchField: "summary", date: episode.publishedAt)
        } else if let field = episode.matchField {
            cell.applySearchHighlight(snippet: nil, matchField: field, date: episode.publishedAt)
        }
    }

    private func isSubscribed(to stableID: String) -> Bool {
        subscriptions.contains { $0.stableID == stableID }
    }

    private var isShowingPopular: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !popularPodcasts.isEmpty
    }

    private var podcastResults: [PodcastSearchResult] {
        var seenFeedURLs: Set<String> = []
        var output: [PodcastSearchResult] = []
        if isShowingPopular {
            for podcast in popularPodcasts {
                guard seenFeedURLs.insert(podcast.feedURL).inserted else { continue }
                output.append(.known(podcast))
            }
            return output
        }
        for podcast in results.podcasts {
            guard seenFeedURLs.insert(podcast.feedURL).inserted else { continue }
            output.append(.known(podcast))
        }
        for podcast in results.directory {
            guard seenFeedURLs.insert(podcast.feedURL).inserted else { continue }
            output.append(.directory(podcast))
        }
        return output
    }

    private var visiblePodcastResults: [PodcastSearchResult] {
        (showAllPodcasts || isShowingPopular) ? podcastResults : Array(podcastResults.prefix(5))
    }

    private var visiblePodcastRowCount: Int {
        visiblePodcastResults.count + (podcastResults.count > visiblePodcastResults.count ? 1 : 0)
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
                self.player.play(playableEpisode, at: LibraryStore.playbackPosition(for: playableEpisode, in: self.modelContext), artworkURL: LibraryStore.localArtworkURL(for: playableEpisode, in: self.modelContext))
            }
        }
    }

    private func showDownloadFailed(for episode: EpisodeDTO) {
        FloatingDownloadHUD.shared.showFailure(progressID: episode.stableID, title: episode.title)
    }

    private func rssFeedURL(from value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host() != nil else {
            return nil
        }
        return url
    }

    #if targetEnvironment(macCatalyst)
    private weak var macSearchField: UISearchTextField?

    private func setupMacSearchHeader() {
        let field = UISearchTextField()
        field.placeholder = "Search or add podcasts"
        field.returnKeyType = .search
        field.translatesAutoresizingMaskIntoConstraints = false
        field.addTarget(self, action: #selector(macSearchFieldChanged), for: .editingChanged)
        field.addTarget(self, action: #selector(macSearchFieldSubmitted), for: .primaryActionTriggered)
        self.macSearchField = field

        let container = UIView()
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            field.heightAnchor.constraint(equalToConstant: 36),
        ])
        container.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 56)
        tableView.tableHeaderView = container
    }

    @objc private func macSearchFieldChanged() {
        query = macSearchField?.text ?? ""
        if query.isEmpty {
            liveSearchTask?.cancel()
            results = EpisodeSearchDTO()
            refreshVisibleEpisodeSnapshot()
            updateRows()
        } else {
            liveSearchTask?.cancel()
            liveSearchTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await submitSearch()
            }
        }
    }

    @objc private func macSearchFieldSubmitted() {
        liveSearchTask?.cancel()
        Task { await submitSearch() }
    }
    #endif

    private func setupCrawlingProgressView() {
        // Configure background
        crawlingBackgroundView.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        crawlingBackgroundView.layer.cornerRadius = 10
        crawlingBackgroundView.layer.shadowColor = UIColor.black.cgColor
        crawlingBackgroundView.layer.shadowOpacity = 0.1
        crawlingBackgroundView.layer.shadowOffset = CGSize(width: 0, height: 2)
        crawlingBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(crawlingBackgroundView)

        // Configure stack view
        crawlingProgressView.axis = .horizontal
        crawlingProgressView.spacing = 8
        crawlingProgressView.alignment = .center
        crawlingProgressView.translatesAutoresizingMaskIntoConstraints = false
        crawlingBackgroundView.addSubview(crawlingProgressView)

        // Configure spinner
        crawlingSpinner.startAnimating()
        crawlingProgressView.addArrangedSubview(crawlingSpinner)

        // Configure label
        crawlingLabel.text = "Server is crawling episodes…"
        crawlingLabel.font = .preferredFont(forTextStyle: .callout)
        crawlingProgressView.addArrangedSubview(crawlingLabel)

        // Constraints for background view (floating at bottom)
        NSLayoutConstraint.activate([
            crawlingBackgroundView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            crawlingBackgroundView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            crawlingBackgroundView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            crawlingBackgroundView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            crawlingProgressView.topAnchor.constraint(equalTo: crawlingBackgroundView.topAnchor, constant: 12),
            crawlingProgressView.bottomAnchor.constraint(equalTo: crawlingBackgroundView.bottomAnchor, constant: -12),
            crawlingProgressView.leadingAnchor.constraint(equalTo: crawlingBackgroundView.leadingAnchor, constant: 16),
            crawlingProgressView.trailingAnchor.constraint(equalTo: crawlingBackgroundView.trailingAnchor, constant: -16)
        ])

        crawlingBackgroundView.isHidden = true
    }

    private func updateCrawlingProgressVisibility() {
        crawlingBackgroundView.isHidden = addingFeedURL == nil
    }
}

private final class SearchPodcastCell: UITableViewCell {
    static let reuseIdentifier = "SearchPodcastCell"
    private let artworkView = ArtworkImageView(cornerRadius: 8)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let addButton = UIButton(type: .system)
    var addTapped: (() -> Void)?

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
        addTapped = nil
    }

    func configure(title: String, subtitle: String, artworkURL: URL?, isSubscribed: Bool, isAdding: Bool) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        artworkView.load(url: artworkURL)
        addButton.isEnabled = !isSubscribed && !isAdding
        addButton.setImage(UIImage(systemName: isSubscribed ? "checkmark.circle.fill" : "plus.circle.fill"), for: .normal)
        addButton.accessibilityLabel = isSubscribed ? "Already added" : "Add \(title)"
    }

    private func configure() {
        selectionStyle = .default
        accessoryType = .disclosureIndicator
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 2
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1
        addButton.tintColor = .systemOrange
        addButton.addTarget(self, action: #selector(add), for: .touchUpInside)

        let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        labels.axis = .vertical
        labels.spacing = 4
        let row = UIStackView(arrangedSubviews: [artworkView, labels, addButton])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.alignment = .center
        row.spacing = 12
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            artworkView.widthAnchor.constraint(equalToConstant: 52),
            artworkView.heightAnchor.constraint(equalToConstant: 52),
            addButton.widthAnchor.constraint(equalToConstant: 44),
            addButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    @objc private func add() {
        addTapped?()
    }
}
