import SwiftData
import UIKit

final class SearchViewController: UITableViewController, UISearchResultsUpdating, UISearchBarDelegate {
    private enum Row {
        case podcast(PodcastDTO)
        case episode(EpisodeDTO)
        case directory(PodcastDirectoryDTO)
    }

    private let modelContext: ModelContext
    private let player: PlayerController
    private let client = BackendClient()
    private var query = ""
    private var results = EpisodeSearchDTO()
    private var visibleEpisodeSnapshot: [EpisodeDTO] = []
    private var subscriptions: [PodcastSubscription] = []
    private var addingFeedURL: String?
    private var playedEpisodeIDs: Set<String> = []
    private var deletedEpisodeIDs: Set<String> = []

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

        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.searchBar.delegate = self
        searchController.searchBar.placeholder = "Search or add podcasts"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        loadSubscriptions()
        updateRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadSubscriptions()
        tableView.reloadData()
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        if query.isEmpty {
            results = EpisodeSearchDTO()
            refreshVisibleEpisodeSnapshot()
            updateRows()
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        Task { await submitSearch() }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        3
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: results.podcasts.isEmpty ? nil : "Known Podcasts"
        case 1: visibleEpisodeSnapshot.isEmpty ? nil : "Episodes"
        case 2: results.directory.isEmpty ? nil : "Apple Podcasts Directory"
        default: nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: results.podcasts.count
        case 1: visibleEpisodeSnapshot.count
        case 2: results.directory.count
        default: 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.section {
        case 0:
            let podcast = results.podcasts[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: SearchPodcastCell.reuseIdentifier, for: indexPath) as! SearchPodcastCell
            cell.configure(title: podcast.title.isEmpty ? podcast.feedURL : podcast.title, subtitle: podcast.feedURL, artworkURL: podcast.imageURL.flatMap(URL.init(string:)), isSubscribed: isSubscribed(to: podcast.stableID), isAdding: addingFeedURL == podcast.feedURL)
            cell.addTapped = { [weak self] in Task { await self?.addKnownPodcast(podcast) } }
            return cell
        case 1:
            let episode = visibleEpisodeSnapshot[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: EpisodeCell.reuseIdentifier, for: indexPath) as! EpisodeCell
            cell.configure(episode: episode, artworkURL: LibraryStore.localArtworkURL(for: episode, in: modelContext), isPlayed: playedEpisodeIDs.contains(episode.stableID), dimsPlayed: false, player: player)
            cell.playTapped = { [weak self] in self?.play(episode) }
            return cell
        default:
            let podcast = results.directory[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: SearchPodcastCell.reuseIdentifier, for: indexPath) as! SearchPodcastCell
            cell.configure(title: podcast.title, subtitle: podcast.artistName ?? podcast.feedURL, artworkURL: podcast.artworkURL.flatMap(URL.init(string:)), isSubscribed: subscriptions.contains { $0.feedURL.absoluteString == podcast.feedURL }, isAdding: addingFeedURL == podcast.feedURL)
            cell.addTapped = { [weak self] in Task { await self?.addDirectoryPodcast(podcast) } }
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        let episode = visibleEpisodeSnapshot[indexPath.row]
        navigationController?.pushViewController(EpisodeDetailViewController(episode: episode, modelContext: modelContext, player: player), animated: true)
    }

    private func submitSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = rssFeedURL(from: trimmed) {
            await addFeedURL(url)
        } else {
            await search(trimmed)
        }
    }

    private func search(_ trimmed: String) async {
        guard !trimmed.isEmpty else { return }
        let localMatches = LibraryStore.localEpisodes(matching: trimmed, in: modelContext)
        if !localMatches.isEmpty {
            results = EpisodeSearchDTO(episodes: localMatches)
            refreshEpisodeStateSets()
            refreshVisibleEpisodeSnapshot()
            tableView.reloadData()
        }

        do {
            let searchResults = try await client.search(trimmed)
            await LibraryStore.cacheEpisodes(searchResults.episodes, in: modelContext)
            Task { await LibraryStore.prefetchDetails(for: searchResults.episodes, client: client, in: modelContext) }
            results = EpisodeSearchDTO(
                podcasts: searchResults.podcasts,
                episodes: LibraryStore.localEpisodes(matching: trimmed, in: modelContext),
                directory: searchResults.directory
            )
            refreshEpisodeStateSets()
            refreshVisibleEpisodeSnapshot()
            updateRows()
        } catch {
            showError(error)
        }
    }

    private func addFeedURL(_ url: URL) async {
        addingFeedURL = url.absoluteString
        tableView.reloadData()
        defer {
            addingFeedURL = nil
            tableView.reloadData()
        }
        do {
            let podcast = try await client.addPodcast(feedURL: url)
            LibraryStore.subscribe(to: podcast, in: modelContext)
            query = ""
            results = EpisodeSearchDTO()
            refreshVisibleEpisodeSnapshot()
            loadSubscriptions()
            updateRows()
        } catch {
            showError(error)
        }
    }

    private func addKnownPodcast(_ podcast: PodcastDTO) async {
        addingFeedURL = podcast.feedURL
        tableView.reloadData()
        LibraryStore.subscribe(to: podcast, in: modelContext)
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
        do {
            let addedPodcast = try await client.addPodcast(feedURL: url)
            LibraryStore.subscribe(to: addedPodcast, in: modelContext)
            loadSubscriptions()
            await search(query.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            showError(error)
        }
    }

    private func updateRows() {
        tableView.reloadData()
        let empty = query.isEmpty ? "Search\nSearch the shared podcast catalog and Apple Podcasts." : "No Results"
        if results.podcasts.isEmpty && visibleEpisodeSnapshot.isEmpty && results.directory.isEmpty {
            let label = UILabel()
            label.text = empty
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            tableView.backgroundView = label
        } else {
            tableView.backgroundView = nil
        }
    }

    private func loadSubscriptions() {
        subscriptions = (try? modelContext.fetch(FetchDescriptor<PodcastSubscription>())) ?? []
    }

    private func refreshEpisodeStateSets() {
        playedEpisodeIDs = LibraryStore.playedEpisodeIDs(for: results.episodes, in: modelContext)
        deletedEpisodeIDs = LibraryStore.deletedEpisodeIDs(for: results.episodes, in: modelContext)
    }

    private func refreshVisibleEpisodeSnapshot() {
        visibleEpisodeSnapshot = results.episodes.filter { !deletedEpisodeIDs.contains($0.stableID) }
    }

    private func isSubscribed(to stableID: String) -> Bool {
        subscriptions.contains { $0.stableID == stableID }
    }

    private func play(_ episode: EpisodeDTO) {
        if player.currentEpisode?.stableID == episode.stableID {
            player.togglePlayPause()
        } else {
            player.play(episode, artworkURL: LibraryStore.localArtworkURL(for: episode, in: modelContext))
        }
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
        selectionStyle = .none
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
