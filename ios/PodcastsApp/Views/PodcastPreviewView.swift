import SwiftData
import UIKit

/// Previews a podcast — its artwork, description and episode list — without
/// subscribing. From here the user can subscribe to the whole show, add a single
/// episode to their library, or play/open any episode.
final class PodcastPreviewViewController: UITableViewController {
    struct Identity {
        let stableID: String
        let feedURL: URL
        let title: String
        let artworkURL: URL?
        let description: String?

        init(stableID: String? = nil, feedURL: URL, title: String, artworkURL: URL?, description: String? = nil) {
            self.stableID = stableID ?? StableID.podcastID(feedURL: feedURL)
            self.feedURL = feedURL
            self.title = title
            self.artworkURL = artworkURL
            self.description = description
        }

        init(podcast: PodcastDTO) {
            self.stableID = podcast.stableID
            self.feedURL = URL(string: podcast.feedURL) ?? URL(string: "about:blank")!
            self.title = podcast.title.isEmpty ? podcast.feedURL : podcast.title
            self.artworkURL = podcast.imageURL.flatMap(URL.init(string:))
            self.description = podcast.description
        }

        init(directory: PodcastDirectoryDTO) {
            self.stableID = StableID.podcastID(feedURL: URL(string: directory.feedURL) ?? URL(string: "about:blank")!)
            self.feedURL = URL(string: directory.feedURL) ?? URL(string: "about:blank")!
            self.title = directory.title
            self.artworkURL = directory.artworkURL.flatMap(URL.init(string:))
            self.description = directory.artistName
        }
    }

    private let modelContext: ModelContext
    private let player: PlayerController
    private let client = BackendClient()
    private var identity: Identity
    private let headerView = PreviewHeaderView()
    private var episodes: [EpisodeDTO] = []
    private var savedEpisodeIDs: Set<String> = []
    private var isLoading = true

    init(identity: Identity, modelContext: ModelContext, player: PlayerController) {
        self.identity = identity
        self.modelContext = modelContext
        self.player = player
        super.init(style: .plain)
        title = identity.title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(EpisodeCell.self, forCellReuseIdentifier: EpisodeCell.reuseIdentifier)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 96
        headerView.configure(identity: identity, isSubscribed: isSubscribed)
        headerView.subscribeTapped = { [weak self] in self?.subscribeToShow() }
        tableView.tableHeaderView = headerView
        loadSavedState()
        Task { await load() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeHeaderToFit()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadSavedState()
        headerView.configure(identity: identity, isSubscribed: isSubscribed)
        tableView.reloadData()
    }

    private func sizeHeaderToFit() {
        guard let header = tableView.tableHeaderView else { return }
        let targetWidth = tableView.bounds.width
        let size = header.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        if abs(header.frame.height - size.height) > 0.5 {
            header.frame.size = CGSize(width: targetWidth, height: size.height)
            tableView.tableHeaderView = header
        }
    }

    private var isSubscribed: Bool {
        let stableID = identity.stableID
        let descriptor = FetchDescriptor<PodcastSubscription>(predicate: #Predicate { $0.stableID == stableID })
        return ((try? modelContext.fetch(descriptor))?.isEmpty == false)
    }

    private func loadSavedState() {
        let states = (try? modelContext.fetch(FetchDescriptor<LocalEpisodeState>())) ?? []
        savedEpisodeIDs = Set(states.filter { $0.isSaved }.map(\.episodeStableID))
    }

    private func load() async {
        isLoading = true
        updateBackground()
        let result = try? await client.previewEpisodes(feedURL: identity.feedURL)
        if let result {
            episodes = result.episodes
            // Hydrate header metadata (description/artwork) from the crawled feed.
            identity = Identity(
                stableID: result.podcast.stableID,
                feedURL: identity.feedURL,
                title: result.podcast.title.isEmpty ? identity.title : result.podcast.title,
                artworkURL: result.podcast.imageURL.flatMap(URL.init(string:)) ?? identity.artworkURL,
                description: result.podcast.description ?? identity.description
            )
            headerView.configure(identity: identity, isSubscribed: isSubscribed)
            sizeHeaderToFit()
            await LibraryStore.cacheEpisodes(episodes, in: modelContext)
        }
        isLoading = false
        loadSavedState()
        tableView.reloadData()
        updateBackground()
    }

    private func updateBackground() {
        if isLoading && episodes.isEmpty {
            let spinner = UIActivityIndicatorView(style: .large)
            spinner.startAnimating()
            tableView.backgroundView = spinner
        } else if episodes.isEmpty {
            let label = UILabel()
            label.text = "No episodes found"
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            tableView.backgroundView = label
        } else {
            tableView.backgroundView = nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        episodes.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let episode = episodes[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: EpisodeCell.reuseIdentifier, for: indexPath) as! EpisodeCell
        let isCurrentPlaying = player.currentEpisode?.stableID == episode.stableID && player.isPlaying
        cell.configure(
            episode: episode,
            summaryText: LibraryStore.summarySnippets(for: [episode], in: modelContext)[episode.stableID] ?? episode.summary,
            artworkURL: LibraryStore.localArtworkURL(for: episode, in: modelContext) ?? identity.artworkURL,
            isPlayed: false,
            dimsPlayed: false,
            isCurrentPlaying: isCurrentPlaying
        )
        cell.playTapped = { [weak self] in self?.play(episode) }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let episode = episodes[indexPath.row]
        navigationController?.pushViewController(EpisodeDetailViewController(episode: episode, modelContext: modelContext, player: player), animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let episode = episodes[indexPath.row]
        let isSaved = savedEpisodeIDs.contains(episode.stableID)
        let action = UIContextualAction(style: .normal, title: isSaved ? "Remove" : "Add Episode") { [weak self] _, _, completion in
            self?.toggleSaved(episode)
            completion(true)
        }
        action.backgroundColor = isSaved ? .systemGray : .systemOrange
        action.image = UIImage(systemName: isSaved ? "minus.circle" : "plus.circle")
        return UISwipeActionsConfiguration(actions: [action])
    }

    override func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let episode = episodes[indexPath.row]
        let play = UIContextualAction(style: .normal, title: "Play") { [weak self] _, _, completion in
            self?.play(episode)
            completion(true)
        }
        play.backgroundColor = .systemBlue
        play.image = UIImage(systemName: "play.fill")
        return UISwipeActionsConfiguration(actions: [play])
    }

    private func toggleSaved(_ episode: EpisodeDTO) {
        if savedEpisodeIDs.contains(episode.stableID) {
            LibraryStore.unsaveSingleEpisode(episode, in: modelContext)
            savedEpisodeIDs.remove(episode.stableID)
            tableView.reloadData()
        } else {
            savedEpisodeIDs.insert(episode.stableID)
            tableView.reloadData()
            Task { await LibraryStore.saveSingleEpisode(episode, in: modelContext) }
        }
    }

    private func subscribeToShow() {
        let placeholder = client.optimisticPodcast(feedURL: identity.feedURL, title: identity.title, imageURL: identity.artworkURL?.absoluteString)
        LibraryStore.subscribe(to: placeholder, in: modelContext)
        headerView.configure(identity: identity, isSubscribed: true)
        Task {
            let added = try? await client.addPodcast(feedURL: identity.feedURL)
            if let added {
                let hydrated = await client.hydratedPodcast(afterAdding: added).fillingMissingImageURL(identity.artworkURL?.absoluteString)
                LibraryStore.subscribe(to: hydrated, in: modelContext)
            }
        }
    }

    private func play(_ episode: EpisodeDTO) {
        if player.currentEpisode?.stableID == episode.stableID {
            player.togglePlayPause()
            return
        }
        if LibraryStore.downloadedEpisode(for: episode, in: modelContext) == nil {
            FloatingDownloadHUD.shared.show(progressID: episode.stableID, title: episode.title)
        }
        Task { [weak self] in
            guard let self else { return }
            guard let playable = await LibraryStore.playableDownloadedEpisode(for: episode, in: self.modelContext) else {
                FloatingDownloadHUD.shared.showFailure(progressID: episode.stableID, title: episode.title)
                return
            }
            self.player.play(playable, at: LibraryStore.playbackPosition(for: playable, in: self.modelContext), artworkURL: LibraryStore.localArtworkURL(for: playable, in: self.modelContext))
            self.tableView.reloadData()
        }
    }
}

private final class PreviewHeaderView: UIView {
    private let artworkView = ArtworkImageView(cornerRadius: 14)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let descriptionLabel = UILabel()
    private let subscribeButton = UIButton(type: .system)
    var subscribeTapped: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(identity: PodcastPreviewViewController.Identity, isSubscribed: Bool) {
        titleLabel.text = identity.title
        subtitleLabel.text = identity.feedURL.host()
        let description = identity.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        descriptionLabel.text = description
        descriptionLabel.isHidden = description?.isEmpty != false
        artworkView.load(url: identity.artworkURL)
        var configuration = UIButton.Configuration.filled()
        configuration.title = isSubscribed ? "Subscribed" : "Subscribe to Show"
        configuration.image = UIImage(systemName: isSubscribed ? "checkmark.circle.fill" : "plus.circle.fill")
        configuration.imagePadding = 6
        configuration.baseBackgroundColor = isSubscribed ? .systemGray4 : .systemOrange
        configuration.baseForegroundColor = isSubscribed ? .label : .white
        subscribeButton.configuration = configuration
        subscribeButton.isEnabled = !isSubscribed
    }

    private func setup() {
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.numberOfLines = 3
        titleLabel.textAlignment = .center
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        descriptionLabel.font = .preferredFont(forTextStyle: .footnote)
        descriptionLabel.textColor = .secondaryLabel
        descriptionLabel.numberOfLines = 4
        descriptionLabel.textAlignment = .center
        subscribeButton.addTarget(self, action: #selector(subscribe), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [artworkView, titleLabel, subtitleLabel, descriptionLabel, subscribeButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(16, after: descriptionLabel)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            artworkView.widthAnchor.constraint(equalToConstant: 160),
            artworkView.heightAnchor.constraint(equalToConstant: 160)
        ])
    }

    @objc private func subscribe() {
        subscribeTapped?()
    }
}
