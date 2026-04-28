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
    private var deletedEpisodeIDs: Set<String> = []

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
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        Task { await load() }
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
        tableView.deselectRow(at: indexPath, animated: true)
        showEpisode(visibleEpisodeSnapshot[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let episode = visibleEpisodeSnapshot[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            guard let self else { return done(false) }
            LibraryStore.markDeleted(episode, in: self.modelContext)
            self.deletedEpisodeIDs.insert(episode.stableID)
            self.refreshVisibleEpisodeSnapshot()
            self.tableView.reloadData()
            done(true)
        }
        let playedTitle = playedEpisodeIDs.contains(episode.stableID) ? "Unplayed" : "Played"
        let played = UIContextualAction(style: .normal, title: playedTitle) { [weak self] _, _, done in
            self?.togglePlayed(episode)
            done(true)
        }
        played.backgroundColor = .systemGreen
        return UISwipeActionsConfiguration(actions: [delete, played])
    }

    override func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let episode = visibleEpisodeSnapshot[indexPath.row]
        let play = UIContextualAction(style: .normal, title: "Play") { [weak self] _, _, done in
            self?.play(episode)
            done(true)
        }
        play.backgroundColor = .systemOrange
        return UISwipeActionsConfiguration(actions: [play])
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let episode = visibleEpisodeSnapshot[indexPath.row]
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [
                UIAction(title: "Play", image: UIImage(systemName: "play.fill")) { _ in self.play(episode) },
                UIAction(title: self.playedEpisodeIDs.contains(episode.stableID) ? "Mark as Unplayed" : "Mark as Played", image: UIImage(systemName: "checkmark.circle")) { _ in self.togglePlayed(episode) },
                UIAction(title: "Share Episode Link", image: UIImage(systemName: "square.and.arrow.up")) { _ in self.share(URL(string: episode.audioURL)) },
                UIAction(title: "Delete Episode", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    LibraryStore.markDeleted(episode, in: self.modelContext)
                    self.deletedEpisodeIDs.insert(episode.stableID)
                    self.refreshVisibleEpisodeSnapshot()
                    self.tableView.reloadData()
                }
            ])
        })
    }

    func showEpisode(_ episode: EpisodeDTO) {
        navigationController?.pushViewController(EpisodeDetailViewController(episode: episode, modelContext: modelContext, player: player), animated: true)
    }

    private var showsPlayedEpisodes: Bool {
        if case .podcast = mode { return true }
        return false
    }

    private func load() async {
        let cached = cachedEpisodes()
        if !cached.isEmpty {
            episodes = cached
            refreshEpisodeStateSets()
            refreshVisibleEpisodeSnapshot()
            tableView.reloadData()
        }

        do {
            episodes = try await loadEpisodes()
            refreshEpisodeStateSets()
            refreshVisibleEpisodeSnapshot()
            tableView.reloadData()
        } catch {
            showError(error)
        }
        refreshControl?.endRefreshing()
        updateEmptyState()
    }

    private func loadEpisodes() async throws -> [EpisodeDTO] {
        switch mode {
        case .podcast(let podcastID):
            let fetched = try await client.episodes(for: podcastID)
            await LibraryStore.cacheEpisodes(fetched, in: modelContext)
            Task { await LibraryStore.prefetchDetails(for: fetched, client: client, in: modelContext) }
            return LibraryStore.localEpisodes(forPodcastIDs: [podcastID], in: modelContext)
        case .subscriptions(let podcastIDs):
            return try await loadSubscriptions(podcastIDs)
        case .search(let query):
            let fetched = try await client.search(query).episodes
            await LibraryStore.cacheEpisodes(fetched, in: modelContext)
            Task { await LibraryStore.prefetchDetails(for: fetched, client: client, in: modelContext) }
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
            Task { await LibraryStore.prefetchDetails(for: fetched, client: client, in: modelContext) }
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
        playedEpisodeIDs = LibraryStore.playedEpisodeIDs(for: episodes, in: modelContext)
        deletedEpisodeIDs = LibraryStore.deletedEpisodeIDs(for: episodes, in: modelContext)
    }

    private func refreshVisibleEpisodeSnapshot() {
        visibleEpisodeSnapshot = episodes.filter { !deletedEpisodeIDs.contains($0.stableID) && (showsPlayedEpisodes || !playedEpisodeIDs.contains($0.stableID)) }
    }

    private func play(_ episode: EpisodeDTO) {
        if player.currentEpisode?.stableID == episode.stableID {
            player.togglePlayPause()
        } else {
            player.play(episode, artworkURL: LibraryStore.localArtworkURL(for: episode, in: modelContext))
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

    private var emptyText: String {
        switch mode {
        case .placeholder: "This smart playlist is not wired yet."
        case .subscriptions(let ids) where ids.isEmpty: "Search for podcasts and add them to your library."
        default: "No crawled episodes yet."
        }
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
    private static let cache = NSCache<NSURL, UIImage>()
    private var task: Task<Void, Never>?
    private var representedURL: URL?
    private var loadedURL: URL?

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

    func load(url: URL?) {
        if loadedURL == url || (representedURL == url && task != nil) {
            return
        }
        cancel()
        representedURL = url
        loadedURL = nil
        image = UIImage(systemName: "waveform")
        backgroundColor = .secondarySystemFill
        guard let url else { return }

        if let cached = Self.cache.object(forKey: url as NSURL) {
            backgroundColor = nil
            image = cached
            loadedURL = url
            return
        }

        let targetSize = bounds.size == .zero ? CGSize(width: 96, height: 96) : bounds.size
        let scale = traitCollection.displayScale
        task = Task.detached(priority: .utility) { [weak self] in
            guard let cgImage = await Self.loadImage(url: url, targetSize: targetSize, scale: scale) else { return }
            await MainActor.run {
                let image = UIImage(cgImage: cgImage)
                Self.cache.setObject(image, forKey: url as NSURL)
                guard self?.representedURL == url else { return }
                self?.backgroundColor = nil
                self?.image = image
                self?.loadedURL = url
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private static func loadImage(url: URL, targetSize: CGSize, scale: CGFloat) async -> CGImage? {
        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            data = try? await URLSession.shared.data(from: url).0
        }
        guard let data else { return nil }
        return downsample(data: data, targetSize: targetSize, scale: scale)
    }

    private static func downsample(data: Data, targetSize: CGSize, scale: CGFloat) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let maxDimension = max(targetSize.width, targetSize.height) * scale
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(160, Int(maxDimension))
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
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
