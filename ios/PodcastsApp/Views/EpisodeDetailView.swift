import Combine
import SwiftData
import UIKit

final class EpisodeDetailViewController: UIViewController {
    private let episode: EpisodeDTO
    private let modelContext: ModelContext
    private let player: PlayerController
    private let client = BackendClient()

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let actionContainer = UIView()
    private let playButton = UIButton(type: .system)
    private let playedButton = UIButton(type: .system)
    private let downloadButton = UIButton(type: .system)
    private let downloadProgressView = UIProgressView(progressViewStyle: .default)
    private let downloadProgressLabel = UILabel()
    private var transcriptText: String?
    private var chapters: [EpisodeChapterDTO] = []
    private var isLoadingTranscript = false
    private var isDownloading = false
    private var didConfigureActionHeader = false
    private var downloadProgressCancellable: AnyCancellable?

    init(episode: EpisodeDTO, modelContext: ModelContext, player: PlayerController) {
        self.episode = episode
        self.modelContext = modelContext
        self.player = player
        super.init(nibName: nil, bundle: nil)
        title = episode.title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        configureScrollView()
        configureActionHeader()
        rebuildContent()
        loadCachedArtifacts()
        Task { await requestTranscript() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateActionHeader()
    }

    private func configureScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 24
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 20, bottom: 36, trailing: 20)
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
    }

    private func configureActionHeader() {
        guard !didConfigureActionHeader else { return }
        didConfigureActionHeader = true

        let titleLabel = UILabel()
        titleLabel.text = episode.title
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0

        let metadataLabel = UILabel()
        metadataLabel.text = episode.publishedAt?.formatted(date: .abbreviated, time: .omitted)
        metadataLabel.font = .preferredFont(forTextStyle: .subheadline)
        metadataLabel.textColor = .secondaryLabel
        metadataLabel.adjustsFontForContentSizeCategory = true

        playButton.configuration = .filled()
        playButton.configuration?.baseBackgroundColor = .systemOrange
        playButton.configuration?.baseForegroundColor = .white
        playButton.configuration?.cornerStyle = .large
        playButton.addTarget(self, action: #selector(playEpisode), for: .touchUpInside)

        configureActionButton(playedButton, title: "Played", systemImage: "checkmark.circle", action: #selector(togglePlayed))

        let shareButton = actionButton(title: "Share", systemImage: "square.and.arrow.up", action: #selector(shareEpisode))
        let podcastButton = actionButton(title: "Podcast", systemImage: "rectangle.stack", action: #selector(openPodcast))
        podcastButton.isEnabled = episode.podcastStableID != nil
        configureActionButton(downloadButton, title: "Download", systemImage: "arrow.down.circle", action: #selector(toggleDownload))

        let secondaryRow = UIStackView(arrangedSubviews: [playedButton, shareButton, podcastButton, downloadButton])
        secondaryRow.translatesAutoresizingMaskIntoConstraints = false
        secondaryRow.axis = .horizontal
        secondaryRow.spacing = 12
        secondaryRow.distribution = .equalSpacing

        downloadProgressView.isHidden = true
        downloadProgressView.tintColor = .systemOrange
        downloadProgressLabel.isHidden = true
        downloadProgressLabel.font = .preferredFont(forTextStyle: .footnote)
        downloadProgressLabel.textColor = .secondaryLabel
        downloadProgressLabel.adjustsFontForContentSizeCategory = true

        let stack = UIStackView(arrangedSubviews: [titleLabel, metadataLabel, playButton, secondaryRow, downloadProgressView, downloadProgressLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 14
        actionContainer.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: actionContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: actionContainer.trailingAnchor),
            stack.topAnchor.constraint(equalTo: actionContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: actionContainer.bottomAnchor),
            playButton.heightAnchor.constraint(equalToConstant: 54),
            secondaryRow.heightAnchor.constraint(equalToConstant: 48)
        ])

        updateActionHeader()
    }

    private func rebuildContent() {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        contentStack.addArrangedSubview(actionContainer)
        contentStack.addArrangedSubview(makeNotesSection())
        contentStack.addArrangedSubview(makeTranscriptSection())
        if chapters.count > 1 {
            contentStack.addArrangedSubview(makeChaptersSection())
        }
        updateActionHeader()
    }

    private func makeNotesSection() -> UIView {
        let notes = episode.summary.map(ShowNotesProcessor.plainText) ?? "No Episode Notes"
        let label = bodyLabel(notes)
        return section(title: "Episode Notes", arrangedSubviews: [label])
    }

    private func makeTranscriptSection() -> UIView {
        if isLoadingTranscript {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()

            let label = bodyLabel("Loading Transcript...")
            let row = UIStackView(arrangedSubviews: [spinner, label])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 10
            return section(title: "Transcript", arrangedSubviews: [row])
        }

        if transcriptText != nil {
            var configuration = UIButton.Configuration.borderedProminent()
            configuration.title = "Show Transcript"
            configuration.image = UIImage(systemName: "doc.text")
            configuration.imagePadding = 8
            configuration.baseBackgroundColor = .systemOrange
            configuration.baseForegroundColor = .white
            configuration.cornerStyle = .large

            let button = UIButton(type: .system)
            button.configuration = configuration
            button.contentHorizontalAlignment = .leading
            button.addTarget(self, action: #selector(showTranscript), for: .touchUpInside)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
            return section(title: "Transcript", arrangedSubviews: [button])
        }

        return section(title: "Transcript", arrangedSubviews: [bodyLabel("No Transcript Yet")])
    }

    private func makeChaptersSection() -> UIView {
        let chapterViews = chapters.map { chapterButton(for: $0) }
        return section(title: "Chapters", arrangedSubviews: chapterViews)
    }

    private func section(title: String, arrangedSubviews: [UIView]) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .secondaryLabel
        stack.addArrangedSubview(titleLabel)

        arrangedSubviews.forEach { stack.addArrangedSubview($0) }
        return stack
    }

    private func bodyLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        return label
    }

    private func chapterButton(for chapter: EpisodeChapterDTO) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = "\(format(chapter.start))  \(chapter.title)"
        configuration.image = UIImage(systemName: "play.circle.fill")
        configuration.imagePadding = 8
        configuration.baseForegroundColor = .systemOrange
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)

        let button = UIButton(type: .system)
        button.configuration = configuration
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.numberOfLines = 0
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            player.play(
                episode,
                at: chapter.start,
                artworkURL: LibraryStore.cachedChapterImageURL(for: chapter, episode: episode, in: modelContext) ?? chapter.displayImageURL ?? artworkURL
            )
        }, for: .touchUpInside)
        return button
    }

    private func actionButton(title: String, systemImage: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        configureActionButton(button, title: title, systemImage: systemImage, action: action)
        return button
    }

    private func configureActionButton(_ button: UIButton, title: String, systemImage: String, action: Selector) {
        var configuration = UIButton.Configuration.bordered()
        configuration.image = UIImage(systemName: systemImage)
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        button.configuration = configuration
        button.accessibilityLabel = title
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 54).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    private func updateActionHeader() {
        let isCurrent = player.currentEpisode?.stableID == episode.stableID
        playButton.configuration?.title = isCurrent && player.isPlaying ? "Pause" : "Play"
        playButton.configuration?.image = UIImage(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
        playButton.configuration?.imagePadding = 8

        let isPlayed = LibraryStore.isPlayed(episode, in: modelContext)
        playedButton.configuration?.image = UIImage(systemName: isPlayed ? "circle" : "checkmark.circle")
        playedButton.accessibilityLabel = isPlayed ? "Mark Unplayed" : "Mark Played"

        let isDownloaded = LibraryStore.episodeState(for: episode, in: modelContext)?.isDownloaded ?? false
        downloadButton.isEnabled = !isDownloading
        downloadButton.configuration?.image = UIImage(systemName: isDownloading ? "arrow.down.circle.dotted" : (isDownloaded ? "trash" : "arrow.down.circle"))
        downloadButton.accessibilityLabel = isDownloading ? "Downloading" : (isDownloaded ? "Remove Download" : "Download")
        downloadButton.tintColor = isDownloaded ? .systemRed : view.tintColor
    }

    private func loadCachedArtifacts() {
        transcriptText = LibraryStore.cachedTranscriptText(for: episode, in: modelContext)
        Task {
            chapters = await preferredChapters()
            rebuildContent()
        }
    }

    private func requestTranscript() async {
        isLoadingTranscript = true
        rebuildContent()
        defer {
            isLoadingTranscript = false
            rebuildContent()
        }
        do {
            _ = try await client.requestArtifacts(for: episode.stableID)
            do {
                let artifact = try await client.transcript(for: episode.stableID)
                await LibraryStore.cacheTranscript(artifact, for: episode, in: modelContext)
                transcriptText = LibraryStore.cachedTranscriptText(for: episode, in: modelContext)
            } catch BackendError.notFound {
                transcriptText = LibraryStore.cachedTranscriptText(for: episode, in: modelContext)
            }
            do {
                let artifact = try await client.chapters(for: episode.stableID)
                LibraryStore.cacheChapters(artifact, for: episode, in: modelContext)
                chapters = await preferredChapters()
            } catch BackendError.notFound {
                chapters = await preferredChapters()
            }
        } catch {
            showError(error)
        }
    }

    private func preferredChapters() async -> [EpisodeChapterDTO] {
        let embedded = await LibraryStore.embeddedChapters(for: episode, in: modelContext)
        if embedded.count > 1 { return embedded }
        return await LibraryStore.cachedChapters(for: episode, in: modelContext)
    }

    private var artworkURL: URL? {
        LibraryStore.localArtworkURL(for: episode, in: modelContext)
    }

    @objc private func playEpisode() {
        if player.currentEpisode?.stableID == episode.stableID {
            player.togglePlayPause()
        } else {
            player.play(episode, at: LibraryStore.playbackPosition(for: episode, in: modelContext), artworkURL: artworkURL)
        }
        updateActionHeader()
    }

    @objc private func togglePlayed() {
        if LibraryStore.isPlayed(episode, in: modelContext) {
            LibraryStore.markUnplayed(episode, in: modelContext)
        } else {
            LibraryStore.markPlayed(episode, in: modelContext)
        }
        updateActionHeader()
    }

    @objc private func shareEpisode() {
        share(URL(string: episode.audioURL))
    }

    @objc private func openPodcast() {
        guard let podcastStableID = episode.podcastStableID else { return }
        var descriptor = FetchDescriptor<PodcastSubscription>(predicate: #Predicate { $0.stableID == podcastStableID })
        descriptor.fetchLimit = 1
        let title = (try? modelContext.fetch(descriptor).first?.title) ?? "Podcast"
        navigationController?.pushViewController(EpisodeListViewController(title: title, podcastID: podcastStableID, modelContext: modelContext, player: player), animated: true)
    }

    @objc private func toggleDownload() {
        let isDownloaded = LibraryStore.episodeState(for: episode, in: modelContext)?.isDownloaded ?? false
        if isDownloaded {
            LibraryStore.removeDownload(for: episode, in: modelContext)
            updateActionHeader()
        } else {
            isDownloading = true
            observeDownloadProgress()
            updateActionHeader()
            Task {
                await LibraryStore.downloadAudio(for: episode, in: modelContext)
                isDownloading = false
                updateActionHeader()
            }
        }
    }

    private func observeDownloadProgress() {
        downloadProgressView.isHidden = false
        downloadProgressLabel.isHidden = false
        downloadProgressLabel.text = "Downloading..."
        downloadProgressView.progress = 0
        downloadProgressCancellable = DownloadProgressCenter.shared.$progresses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progresses in
                guard let self, let progress = progresses[episode.stableID] else { return }
                self.downloadProgressView.setProgress(Float(progress.fractionCompleted), animated: true)
                self.downloadProgressLabel.text = progress.isFinished ? "Download complete" : "Downloading \(progress.percentText)"
                if progress.isFinished {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        self.downloadProgressView.isHidden = true
                        self.downloadProgressLabel.isHidden = true
                        DownloadProgressCenter.shared.clear(id: self.episode.stableID)
                    }
                }
            }
    }

    @objc private func showTranscript() {
        guard let transcriptText else { return }
        let segments = LibraryStore.cachedTranscriptSegments(for: episode, in: modelContext)
        navigationController?.pushViewController(
            TranscriptTextViewController(
                episode: episode,
                text: transcriptText,
                segments: segments,
                artworkURL: artworkURL,
                player: player
            ),
            animated: true
        )
    }

    private func format(_ value: TimeInterval) -> String {
        TimeFormatting.playbackTime(value)
    }
}

private final class TranscriptTextViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating {
    private let episode: EpisodeDTO
    private let text: String
    private let segments: [TranscriptSegment]
    private let artworkURL: URL?
    private let player: PlayerController
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var filteredSegments: [TranscriptSegment] = []
    private var currentSegmentStart: TimeInterval?
    private var cancellables: Set<AnyCancellable> = []

    init(episode: EpisodeDTO, text: String, segments: [TranscriptSegment], artworkURL: URL?, player: PlayerController) {
        self.episode = episode
        self.text = text
        self.segments = segments
        self.filteredSegments = segments
        self.artworkURL = artworkURL
        self.player = player
        super.init(nibName: nil, bundle: nil)
        title = "Transcript"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureSearch()
        configureTableView()
        bindPlayer()
    }

    private func configureSearch() {
        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search transcript"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 88
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 88, bottom: 0, right: 20)
        tableView.register(TranscriptSegmentCell.self, forCellReuseIdentifier: TranscriptSegmentCell.reuseIdentifier)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func bindPlayer() {
        player.$elapsed
            .combineLatest(player.$currentEpisode)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] elapsed, currentEpisode in
                self?.updateCurrentSegment(elapsed: elapsed, currentEpisode: currentEpisode)
            }
            .store(in: &cancellables)
    }

    private func updateCurrentSegment(elapsed: TimeInterval, currentEpisode: EpisodeDTO?) {
        guard currentEpisode?.stableID == episode.stableID else {
            guard currentSegmentStart != nil else { return }
            currentSegmentStart = nil
            tableView.reloadData()
            return
        }

        let segment = segments.last { transcriptSegment in
            guard let start = transcriptSegment.start else { return false }
            return start <= elapsed
        }
        guard segment?.start != currentSegmentStart else { return }
        currentSegmentStart = segment?.start
        tableView.reloadData()
        scrollCurrentSegmentIntoViewIfNeeded()
    }

    private func scrollCurrentSegmentIntoViewIfNeeded() {
        guard let currentSegmentStart,
              let row = filteredSegments.firstIndex(where: { $0.start == currentSegmentStart }) else {
            return
        }
        let indexPath = IndexPath(row: row, section: 0)
        guard tableView.indexPathsForVisibleRows?.contains(indexPath) == false else { return }
        tableView.scrollToRow(at: indexPath, at: .middle, animated: true)
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if query.isEmpty {
            filteredSegments = segments
        } else {
            filteredSegments = segments.filter { $0.text.localizedCaseInsensitiveContains(query) }
        }
        tableView.reloadData()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        segments.isEmpty ? 1 : filteredSegments.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TranscriptSegmentCell.reuseIdentifier, for: indexPath) as! TranscriptSegmentCell
        if segments.isEmpty {
            cell.configure(time: nil, text: text, isCurrent: false)
        } else {
            let segment = filteredSegments[indexPath.row]
            cell.configure(time: segment.start.map(format), text: segment.text, isCurrent: segment.start == currentSegmentStart)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !segments.isEmpty, let start = filteredSegments[indexPath.row].start else { return }
        if player.currentEpisode?.stableID == episode.stableID {
            player.seek(toTime: start)
        } else {
            player.play(episode, at: start, artworkURL: artworkURL)
        }
    }

    private func format(_ value: TimeInterval) -> String {
        TimeFormatting.playbackTime(value)
    }
}

private final class TranscriptSegmentCell: UITableViewCell {
    static let reuseIdentifier = "TranscriptSegmentCell"
    private let timeLabel = UILabel()
    private let transcriptLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(time: String?, text: String, isCurrent: Bool) {
        timeLabel.text = time
        transcriptLabel.text = text
        contentView.backgroundColor = isCurrent ? UIColor.systemOrange.withAlphaComponent(0.18) : .clear
        transcriptLabel.textColor = isCurrent ? .label : .secondaryLabel
        timeLabel.textColor = isCurrent ? .systemOrange : .tertiaryLabel
    }

    private func configure() {
        selectionStyle = .default
        backgroundColor = .systemBackground
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        transcriptLabel.font = .preferredFont(forTextStyle: .title3)
        transcriptLabel.adjustsFontForContentSizeCategory = true
        transcriptLabel.numberOfLines = 0

        let row = UIStackView(arrangedSubviews: [timeLabel, transcriptLabel])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.alignment = .firstBaseline
        row.spacing = 16
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            timeLabel.widthAnchor.constraint(equalToConstant: 52)
        ])
    }
}

enum TranscriptRenderer {
    static func segments(from segmentsJSON: String) -> [TranscriptSegment] {
        guard let data = segmentsJSON.data(using: .utf8),
              let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: data) else {
            return []
        }
        return segments
    }

    static func render(segmentsJSON: String) -> String {
        let segments = segments(from: segmentsJSON)
        return segments.isEmpty ? segmentsJSON : segments.map(\.text).joined(separator: "\n")
    }
}

struct TranscriptSegment: Decodable, Equatable {
    let start: TimeInterval?
    let end: TimeInterval?
    let text: String
}

enum ChapterRenderer {
    static func render(chaptersJSON: String) -> [EpisodeChapterDTO] {
        guard let data = chaptersJSON.data(using: .utf8),
              let chapters = try? JSONDecoder().decode([EpisodeChapterDTO].self, from: data) else {
            return []
        }
        return chapters
    }
}
