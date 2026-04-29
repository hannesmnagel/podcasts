import AVKit
import Combine
import SwiftData
import UIKit

final class NowPlayingViewController: UIViewController, UIGestureRecognizerDelegate, UIScrollViewDelegate, UITableViewDataSource, UITableViewDelegate {
    private enum DisplayMode {
        case artwork
        case transcript
        case chaptersAndNotes
    }

    private let modelContext: ModelContext
    private let player: PlayerController
    private let client = BackendClient()
    private var cancellables: Set<AnyCancellable> = []
    private var transcriptText: String?
    private var transcriptSegments: [TranscriptSegment] = []
    private var currentTranscriptSegmentIndex: Int?
    private var chapters: [EpisodeChapterDTO] = []
    private var displayMode: DisplayMode = .artwork
    private var swipePanelCacheKey: String?
    private var appliedSpeedEpisodeID: String?
    private var didSetInitialMediaPage = false
    private var hasInteractedWithMediaPager = false

    var showEpisodeDetails: ((EpisodeDTO) -> Void)?
    var showPodcast: ((EpisodeDTO) -> Void)?

    private let podcastLabel = UILabel()
    private let titleLabel = UILabel()
    private let dateLabel = UILabel()
    private let contentContainer = UIScrollView()
    private let mediaPageStack = UIStackView()
    private let artworkPage = UIView()
    private let currentChapterLabel = UILabel()
    private let artworkView = ArtworkImageView(cornerRadius: 20)
    private let transcriptTableView = UITableView(frame: .zero, style: .plain)
    private let transcriptPlaceholderLabel = UILabel()
    private let chaptersNotesScrollView = UIScrollView()
    private let chaptersNotesStack = UIStackView()
    private let progressControl = PlaybackProgressControl()
    private let chapterBackButton = UIButton(type: .system)
    private let chapterForwardButton = UIButton(type: .system)
    private var artworkDismissPan: UIPanGestureRecognizer?
    private var progressHeightConstraint: NSLayoutConstraint?
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private var dragStartY: CGFloat = 0

    init(modelContext: ModelContext, player: PlayerController) {
        self.modelContext = modelContext
        self.player = player
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.1, alpha: 1)
        overrideUserInterfaceStyle = .dark
        configureLayout()
        configureDismissGesture()
        bindPlayer()
        update()
        Task { @MainActor in
            await Task.yield()
            ensureInitialMediaPage()
        }
        Task {
            loadCachedArtifacts()
            await loadArtifacts()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        ensureInitialMediaPage()
    }

    private func ensureInitialMediaPage() {
        guard contentContainer.bounds.width > 0 else { return }
        guard displayMode == .artwork, !hasInteractedWithMediaPager else { return }
        let width = contentContainer.bounds.width
        guard contentContainer.contentSize.width >= width * 2.5 else { return }
        let targetOffset = CGPoint(x: width, y: 0)
        guard !didSetInitialMediaPage || abs(contentContainer.contentOffset.x - targetOffset.x) > 0.5 else { return }
        didSetInitialMediaPage = true
        contentContainer.setContentOffset(targetOffset, animated: false)
    }

    private func configureLayout() {
        podcastLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        podcastLabel.textColor = .secondaryLabel
        podcastLabel.numberOfLines = 1
        podcastLabel.text = "NOW PLAYING"
        podcastLabel.adjustsFontForContentSizeCategory = true
        podcastLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        podcastLabel.setContentHuggingPriority(.required, for: .vertical)

        titleLabel.font = .systemFont(ofSize: 24, weight: .regular)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        titleLabel.setContentHuggingPriority(.required, for: .vertical)

        dateLabel.font = .preferredFont(forTextStyle: .caption1)
        dateLabel.textColor = .secondaryLabel
        dateLabel.adjustsFontForContentSizeCategory = true
        dateLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        dateLabel.setContentHuggingPriority(.required, for: .vertical)

        let titleStack = UIStackView(arrangedSubviews: [podcastLabel, titleLabel, dateLabel])
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.axis = .vertical
        titleStack.spacing = 5
        titleStack.setContentCompressionResistancePriority(.required, for: .vertical)
        titleStack.setContentHuggingPriority(.required, for: .vertical)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.clipsToBounds = true
        contentContainer.layer.cornerRadius = 20
        contentContainer.delegate = self
        contentContainer.isPagingEnabled = true
        contentContainer.showsHorizontalScrollIndicator = false
        contentContainer.showsVerticalScrollIndicator = false
        contentContainer.alwaysBounceHorizontal = true
        contentContainer.alwaysBounceVertical = false
        contentContainer.isDirectionalLockEnabled = true
        contentContainer.contentInsetAdjustmentBehavior = .never
        mediaPageStack.translatesAutoresizingMaskIntoConstraints = false
        mediaPageStack.axis = .horizontal
        mediaPageStack.spacing = 0
        mediaPageStack.distribution = .fillEqually

        artworkPage.translatesAutoresizingMaskIntoConstraints = false
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        currentChapterLabel.translatesAutoresizingMaskIntoConstraints = false
        currentChapterLabel.font = .preferredFont(forTextStyle: .caption2)
        currentChapterLabel.textColor = .tertiaryLabel
        currentChapterLabel.textAlignment = .center
        currentChapterLabel.numberOfLines = 1
        currentChapterLabel.adjustsFontForContentSizeCategory = true
        currentChapterLabel.lineBreakMode = .byTruncatingTail
        artworkPage.addSubview(artworkView)
        artworkPage.addSubview(currentChapterLabel)

        transcriptTableView.translatesAutoresizingMaskIntoConstraints = false
        transcriptTableView.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        transcriptTableView.separatorStyle = .none
        transcriptTableView.showsVerticalScrollIndicator = false
        transcriptTableView.alwaysBounceVertical = true
        transcriptTableView.contentInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        transcriptTableView.dataSource = self
        transcriptTableView.delegate = self
        transcriptTableView.register(NowPlayingTranscriptSegmentCell.self, forCellReuseIdentifier: NowPlayingTranscriptSegmentCell.reuseIdentifier)
        transcriptTableView.rowHeight = UITableView.automaticDimension
        transcriptTableView.estimatedRowHeight = 88
        transcriptTableView.layer.cornerRadius = 20
        transcriptTableView.clipsToBounds = true

        transcriptPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false
        transcriptPlaceholderLabel.textColor = .secondaryLabel
        transcriptPlaceholderLabel.font = .preferredFont(forTextStyle: .title3)
        transcriptPlaceholderLabel.adjustsFontForContentSizeCategory = true
        transcriptPlaceholderLabel.numberOfLines = 0
        transcriptPlaceholderLabel.textAlignment = .center
        transcriptPlaceholderLabel.isHidden = true
        transcriptTableView.backgroundView = transcriptPlaceholderLabel

        chaptersNotesScrollView.translatesAutoresizingMaskIntoConstraints = false
        chaptersNotesScrollView.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        chaptersNotesScrollView.layer.cornerRadius = 20
        chaptersNotesScrollView.clipsToBounds = true
        chaptersNotesStack.translatesAutoresizingMaskIntoConstraints = false
        chaptersNotesStack.axis = .vertical
        chaptersNotesStack.spacing = 12
        chaptersNotesStack.isLayoutMarginsRelativeArrangement = true
        chaptersNotesStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)
        chaptersNotesScrollView.addSubview(chaptersNotesStack)
        [transcriptTableView, artworkPage, chaptersNotesScrollView].forEach(mediaPageStack.addArrangedSubview)
        contentContainer.addSubview(mediaPageStack)

        progressControl.translatesAutoresizingMaskIntoConstraints = false
        progressControl.valueChanged = { [weak self] value in
            self?.player.seek(to: value)
        }
        progressControl.trackingChanged = { [weak self] isTracking in
            self?.progressHeightConstraint?.constant = isTracking ? 48 : 34
            UIView.animate(withDuration: 0.18) {
                self?.view.layoutIfNeeded()
            }
        }
        configureChapterSkipButton(chapterBackButton, systemName: "backward.end.fill", action: #selector(skipChapterBack))
        configureChapterSkipButton(chapterForwardButton, systemName: "forward.end.fill", action: #selector(skipChapterForward))
        let progressRow = UIStackView(arrangedSubviews: [chapterBackButton, progressControl, chapterForwardButton])
        progressRow.translatesAutoresizingMaskIntoConstraints = false
        progressRow.axis = .horizontal
        progressRow.alignment = .center
        progressRow.spacing = 10
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        remainingLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        elapsedLabel.textColor = .secondaryLabel
        remainingLabel.textColor = .secondaryLabel

        let timeRow = UIStackView(arrangedSubviews: [elapsedLabel, UIView(), remainingLabel])
        timeRow.translatesAutoresizingMaskIntoConstraints = false
        timeRow.axis = .horizontal

        let backButton = controlButton(systemName: "gobackward.15", action: #selector(skipBack))
        playButton.tintColor = .systemOrange
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 64, weight: .regular), forImageIn: .normal)
        playButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        let forwardButton = controlButton(systemName: "goforward.30", action: #selector(skipForward))
        let controls = UIStackView(arrangedSubviews: [backButton, playButton, forwardButton])
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.distribution = .equalSpacing
        controls.alignment = .center

        let routePicker = AVRoutePickerView()
        routePicker.translatesAutoresizingMaskIntoConstraints = false
        routePicker.activeTintColor = .label
        routePicker.tintColor = .label

        let closeGlass = glassButton(systemName: "chevron.down", action: #selector(close), diameter: 50)
        let audioButton = glassPlainButton(systemName: "waveform")
        audioButton.addTarget(self, action: #selector(showAudioSettings), for: .touchUpInside)
        let sleepButton = glassPlainButton(systemName: "timer")
        sleepButton.addTarget(self, action: #selector(showSleepTimer), for: .touchUpInside)
        let centerGlass = glassCapsule(arrangedSubviews: [audioButton, routePicker, sleepButton])
        let menuGlass = glassMenuButton(diameter: 50)

        let bottom = UIStackView(arrangedSubviews: [closeGlass, centerGlass, menuGlass])
        bottom.translatesAutoresizingMaskIntoConstraints = false
        bottom.distribution = .equalSpacing
        bottom.alignment = .center

        [titleStack, contentContainer, progressRow, timeRow, controls, bottom].forEach(view.addSubview)
        let artworkWidth = contentContainer.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.94)

        progressHeightConstraint = progressControl.heightAnchor.constraint(equalToConstant: 34)
        NSLayoutConstraint.activate([
            titleStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            titleStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            titleStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),

            contentContainer.topAnchor.constraint(equalTo: titleStack.bottomAnchor, constant: 10),
            contentContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            artworkWidth,
            contentContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 370),
            contentContainer.heightAnchor.constraint(equalTo: contentContainer.widthAnchor),

            mediaPageStack.leadingAnchor.constraint(equalTo: contentContainer.contentLayoutGuide.leadingAnchor),
            mediaPageStack.trailingAnchor.constraint(equalTo: contentContainer.contentLayoutGuide.trailingAnchor),
            mediaPageStack.topAnchor.constraint(equalTo: contentContainer.contentLayoutGuide.topAnchor),
            mediaPageStack.bottomAnchor.constraint(equalTo: contentContainer.contentLayoutGuide.bottomAnchor),
            mediaPageStack.heightAnchor.constraint(equalTo: contentContainer.frameLayoutGuide.heightAnchor),
            mediaPageStack.widthAnchor.constraint(equalTo: contentContainer.frameLayoutGuide.widthAnchor, multiplier: 3),
            transcriptTableView.widthAnchor.constraint(equalTo: contentContainer.frameLayoutGuide.widthAnchor),
            artworkPage.widthAnchor.constraint(equalTo: contentContainer.frameLayoutGuide.widthAnchor),
            artworkView.leadingAnchor.constraint(equalTo: artworkPage.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: artworkPage.trailingAnchor),
            artworkView.topAnchor.constraint(equalTo: artworkPage.topAnchor),
            artworkView.bottomAnchor.constraint(equalTo: currentChapterLabel.topAnchor, constant: -5),
            currentChapterLabel.leadingAnchor.constraint(equalTo: artworkPage.leadingAnchor, constant: 8),
            currentChapterLabel.trailingAnchor.constraint(equalTo: artworkPage.trailingAnchor, constant: -8),
            currentChapterLabel.bottomAnchor.constraint(equalTo: artworkPage.bottomAnchor),
            currentChapterLabel.heightAnchor.constraint(equalToConstant: 16),
            chaptersNotesScrollView.widthAnchor.constraint(equalTo: contentContainer.frameLayoutGuide.widthAnchor),
            chaptersNotesStack.leadingAnchor.constraint(equalTo: chaptersNotesScrollView.contentLayoutGuide.leadingAnchor),
            chaptersNotesStack.trailingAnchor.constraint(equalTo: chaptersNotesScrollView.contentLayoutGuide.trailingAnchor),
            chaptersNotesStack.topAnchor.constraint(equalTo: chaptersNotesScrollView.contentLayoutGuide.topAnchor),
            chaptersNotesStack.bottomAnchor.constraint(equalTo: chaptersNotesScrollView.contentLayoutGuide.bottomAnchor),
            chaptersNotesStack.widthAnchor.constraint(equalTo: chaptersNotesScrollView.frameLayoutGuide.widthAnchor),

            progressRow.topAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: 22),
            progressRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            progressRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),
            progressRow.heightAnchor.constraint(equalToConstant: 44),
            progressHeightConstraint!,
            timeRow.topAnchor.constraint(equalTo: progressControl.bottomAnchor, constant: 0),
            timeRow.leadingAnchor.constraint(equalTo: progressControl.leadingAnchor),
            timeRow.trailingAnchor.constraint(equalTo: progressControl.trailingAnchor),
            chapterBackButton.widthAnchor.constraint(equalToConstant: 44),
            chapterBackButton.heightAnchor.constraint(equalToConstant: 44),
            chapterForwardButton.widthAnchor.constraint(equalToConstant: 44),
            chapterForwardButton.heightAnchor.constraint(equalToConstant: 44),

            controls.topAnchor.constraint(equalTo: timeRow.bottomAnchor, constant: 34),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 86),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -86),
            controls.bottomAnchor.constraint(lessThanOrEqualTo: bottom.topAnchor, constant: -22),
            playButton.widthAnchor.constraint(equalToConstant: 84),
            playButton.heightAnchor.constraint(equalToConstant: 84),

            bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            bottom.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            bottom.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),
            closeGlass.widthAnchor.constraint(equalToConstant: 50),
            closeGlass.heightAnchor.constraint(equalToConstant: 50),
            centerGlass.widthAnchor.constraint(greaterThanOrEqualToConstant: 178),
            centerGlass.heightAnchor.constraint(equalToConstant: 50),
            menuGlass.widthAnchor.constraint(equalToConstant: 50),
            menuGlass.heightAnchor.constraint(equalToConstant: 50),
            routePicker.widthAnchor.constraint(equalToConstant: 38),
            routePicker.heightAnchor.constraint(equalToConstant: 38)
        ])

        contentContainer.setContentHuggingPriority(.required, for: .vertical)
        progressControl.setContentCompressionResistancePriority(.required, for: .vertical)
        updateContentMode(animated: false)
    }

    private func controlButton(systemName: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = .systemOrange
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 72),
            button.heightAnchor.constraint(equalToConstant: 72)
        ])
        return button
    }

    private func configureChapterSkipButton(_ button: UIButton, systemName: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = .systemOrange
        button.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold), forImageIn: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.accessibilityLabel = systemName.hasPrefix("backward") ? "Previous Chapter" : "Next Chapter"
    }

    private func menuButton() -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        button.tintColor = .label
        button.menu = makeMenu()
        button.showsMenuAsPrimaryAction = true
        return button
    }

    private func glassPlainButton(systemName: String) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = .label
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44)
        ])
        return button
    }

    private func glassButton(systemName: String, action: Selector, diameter: CGFloat) -> UIVisualEffectView {
        let blur = glassContainer(cornerRadius: diameter / 2)
        let button = glassPlainButton(systemName: systemName)
        button.addTarget(self, action: action, for: .touchUpInside)
        blur.contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: blur.contentView.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: blur.contentView.centerYAnchor)
        ])
        return blur
    }

    private func glassMenuButton(diameter: CGFloat) -> UIVisualEffectView {
        let blur = glassContainer(cornerRadius: diameter / 2)
        let button = menuButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: blur.contentView.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: blur.contentView.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44)
        ])
        return blur
    }

    private func glassCapsule(arrangedSubviews: [UIView]) -> UIVisualEffectView {
        let blur = glassContainer(cornerRadius: 25)
        let stack = UIStackView(arrangedSubviews: arrangedSubviews)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .equalSpacing
        stack.spacing = 6
        blur.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 1),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -1)
        ])
        return blur
    }

    private func glassContainer(cornerRadius: CGFloat) -> UIVisualEffectView {
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.clipsToBounds = true
        blur.layer.cornerRadius = cornerRadius
        blur.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        blur.layer.borderWidth = 1
        return blur
    }

    private func bindPlayer() {
        player.$currentEpisode.combineLatest(player.$isPlaying, player.$elapsed, player.$duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in self?.update() }
            .store(in: &cancellables)
        player.$speed.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.update() }.store(in: &cancellables)
    }

    private func configureDismissGesture() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        let artworkPan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        artworkPan.delegate = self
        artworkView.addGestureRecognizer(artworkPan)
        artworkView.isUserInteractionEnabled = true
        artworkDismissPan = artworkPan
    }

    private func update() {
        guard let episode = player.currentEpisode else {
            titleLabel.text = "Nothing Playing"
            return
        }
        applyPlaybackSettingsIfNeeded(for: episode)
        titleLabel.text = episode.title
        podcastLabel.text = podcastTitle(for: episode).uppercased()
        dateLabel.text = episode.publishedAt?.formatted(date: .abbreviated, time: .omitted)
        artworkView.load(url: primaryArtworkURL(for: episode), minimumPixelDimension: 1200)
        currentChapterLabel.text = currentChapterTitle()
        updateSwipePanelsIfNeeded(for: episode)
        updateTranscriptPlaybackPosition()
        playButton.setImage(UIImage(systemName: player.isPlaying ? "pause.fill" : "play.fill"), for: .normal)
        progressControl.isEnabled = player.duration != nil
        progressControl.value = progress
        updateChapterSkipButtons()
        elapsedLabel.text = format(player.elapsed)
        remainingLabel.text = "-\(format(remaining))"
    }

    private func updateChapterSkipButtons() {
        let hasChapters = chapters.count > 1
        chapterBackButton.isEnabled = hasChapters
        chapterForwardButton.isEnabled = hasChapters
        chapterBackButton.alpha = hasChapters ? 1 : 0.35
        chapterForwardButton.alpha = hasChapters ? 1 : 0.35
    }

    private func updateSwipePanelsIfNeeded(for episode: EpisodeDTO) {
        let cacheKey = [
            episode.stableID,
            String(transcriptText?.hashValue ?? 0),
            String(transcriptSegments.map { "\($0.start ?? -1):\($0.text)" }.joined(separator: "|").hashValue),
            String(chapters.map(\.title).joined(separator: "|").hashValue),
            String((episode.summary ?? "").hashValue)
        ].joined(separator: ":")
        guard cacheKey != swipePanelCacheKey else { return }
        swipePanelCacheKey = cacheKey
        rebuildTranscriptPanel()
        rebuildChaptersNotes(for: episode)
    }

    private func rebuildTranscriptPanel() {
        currentTranscriptSegmentIndex = nil

        guard !transcriptSegments.isEmpty else {
            let text = transcriptText?.isEmpty == false ? transcriptText! : "No transcript yet."
            transcriptPlaceholderLabel.text = text
            transcriptPlaceholderLabel.isHidden = false
            transcriptTableView.reloadData()
            return
        }

        transcriptPlaceholderLabel.text = nil
        transcriptPlaceholderLabel.isHidden = true
        transcriptTableView.reloadData()
    }

    private func updateTranscriptPlaybackPosition() {
        guard player.currentEpisode != nil, !transcriptSegments.isEmpty else { return }
        let segmentIndex = transcriptSegments.lastIndex { segment in
            guard let start = segment.start else { return false }
            return start <= player.elapsed
        }
        guard segmentIndex != currentTranscriptSegmentIndex else { return }
        let previousIndex = currentTranscriptSegmentIndex
        currentTranscriptSegmentIndex = segmentIndex
        applyTranscriptHighlight(previousIndex: previousIndex, scroll: displayMode == .transcript)
    }

    private func applyTranscriptHighlight(previousIndex: Int? = nil, scroll: Bool) {
        guard !transcriptSegments.isEmpty else { return }
        let changed = [previousIndex, currentTranscriptSegmentIndex]
            .compactMap { $0 }
            .filter { transcriptSegments.indices.contains($0) }
        if !changed.isEmpty {
            let indexPaths = Array(Set(changed)).map { IndexPath(row: $0, section: 0) }
            transcriptTableView.reloadRows(at: indexPaths, with: .none)
        }
        if scroll, let currentTranscriptSegmentIndex {
            scrollTranscriptToSegmentIfNeeded(currentTranscriptSegmentIndex)
        }
    }

    private func scrollTranscriptToSegmentIfNeeded(_ index: Int) {
        guard !transcriptTableView.isDragging,
              !transcriptTableView.isDecelerating,
              !transcriptTableView.isTracking,
              transcriptSegments.indices.contains(index) else { return }

        let indexPath = IndexPath(row: index, section: 0)
        transcriptTableView.layoutIfNeeded()
        let rowRect = transcriptTableView.rectForRow(at: indexPath)
        guard rowRect != .zero else { return }

        let visibleTop = transcriptTableView.contentOffset.y + transcriptTableView.adjustedContentInset.top
        let visibleBottom = transcriptTableView.contentOffset.y + transcriptTableView.bounds.height - transcriptTableView.adjustedContentInset.bottom
        let targetCenterY = rowRect.midY
        let visibleCenterY = (visibleTop + visibleBottom) / 2
        guard abs(targetCenterY - visibleCenterY) > rowRect.height / 2 else { return }

        let centeredOffset = targetCenterY - transcriptTableView.bounds.height / 2
        let minOffset = -transcriptTableView.adjustedContentInset.top
        let maxOffset = max(minOffset, transcriptTableView.contentSize.height - transcriptTableView.bounds.height + transcriptTableView.adjustedContentInset.bottom)
        transcriptTableView.setContentOffset(
            CGPoint(x: 0, y: min(maxOffset, max(minOffset, centeredOffset))),
            animated: true
        )
    }

    private func rebuildChaptersNotes(for episode: EpisodeDTO) {
        chaptersNotesStack.arrangedSubviews.forEach { view in
            chaptersNotesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let chaptersTitle = panelTitle("Chapters")
        chaptersNotesStack.addArrangedSubview(chaptersTitle)

        if chapters.isEmpty {
            chaptersNotesStack.addArrangedSubview(panelBody("No chapters yet."))
        } else {
            chapters.forEach { chapter in
                chaptersNotesStack.addArrangedSubview(chapterButton(for: chapter, episode: episode))
            }
        }

        let notesTitle = panelTitle("Show Notes")
        notesTitle.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 0, trailing: 0)
        chaptersNotesStack.addArrangedSubview(notesTitle)
        if let summary = episode.summary, !summary.isEmpty {
            chaptersNotesStack.addArrangedSubview(ShowNotesText.view(raw: summary, textColor: .label, secondaryColor: .secondaryLabel))
        } else {
            chaptersNotesStack.addArrangedSubview(panelBody("No show notes."))
        }
    }

    private func panelTitle(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .label
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func panelBody(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func chapterButton(for chapter: EpisodeChapterDTO, episode: EpisodeDTO) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = "\(format(chapter.start))  \(chapter.title)"
        configuration.image = UIImage(systemName: "play.circle.fill")
        configuration.imagePadding = 8
        configuration.baseForegroundColor = .systemOrange
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)

        let button = UIButton(type: .system)
        button.configuration = configuration
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.numberOfLines = 0
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            player.play(
                episode,
                at: chapter.start,
                artworkURL: LibraryStore.cachedChapterImageURL(for: chapter, episode: episode, in: modelContext) ?? chapter.displayImageURL ?? currentArtworkURL(for: episode)
            )
        }, for: .touchUpInside)
        return button
    }

    private func updateContentMode(animated: Bool) {
        let width = contentContainer.bounds.width
        guard width > 0 else { return }
        let page: CGFloat = switch displayMode {
        case .transcript: 0
        case .artwork: 1
        case .chaptersAndNotes: 2
        }
        contentContainer.setContentOffset(CGPoint(x: width * page, y: 0), animated: animated)
        if displayMode == .transcript {
            applyTranscriptHighlight(scroll: true)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === contentContainer else { return }
        updateDisplayModeForCurrentPage()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === contentContainer else { return }
        hasInteractedWithMediaPager = true
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === contentContainer else { return }
        if !decelerate {
            updateDisplayModeForCurrentPage()
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView === contentContainer else { return }
        updateDisplayModeForCurrentPage()
    }

    private func updateDisplayModeForCurrentPage() {
        let width = max(1, contentContainer.bounds.width)
        let page = Int((contentContainer.contentOffset.x / width).rounded())
        displayMode = switch min(2, max(0, page)) {
        case 0: .transcript
        case 2: .chaptersAndNotes
        default: .artwork
        }
        if displayMode == .transcript {
            applyTranscriptHighlight(scroll: true)
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        transcriptSegments.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: NowPlayingTranscriptSegmentCell.reuseIdentifier, for: indexPath) as! NowPlayingTranscriptSegmentCell
        let segment = transcriptSegments[indexPath.row]
        cell.configure(
            time: segment.start.map(format),
            text: segment.text,
            isCurrent: indexPath.row == currentTranscriptSegmentIndex
        )
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard transcriptSegments.indices.contains(indexPath.row),
              let start = transcriptSegments[indexPath.row].start else { return }
        let previousIndex = currentTranscriptSegmentIndex
        currentTranscriptSegmentIndex = indexPath.row
        applyTranscriptHighlight(previousIndex: previousIndex, scroll: false)
        player.seek(toTime: start)
    }

    private func makeMenu() -> UIMenu {
        let episodeProvider = { [weak self] in self?.player.currentEpisode }
        return UIMenu(children: [
            UIAction(title: "View Episode Details", image: UIImage(systemName: "info.circle")) { [weak self] _ in
                guard let episode = episodeProvider() else { return }
                self?.showEpisodeDetails?(episode)
            },
            UIAction(title: "Mark Played", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
                guard let self, let episode = episodeProvider() else { return }
                LibraryStore.markPlayed(episode, in: self.modelContext)
            },
            UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                guard let self, let episode = episodeProvider() else { return }
                self.share(URL(string: episode.audioURL))
            },
            UIAction(title: "Remove Download", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                guard let self, let episode = episodeProvider() else { return }
                LibraryStore.removeDownload(for: episode, in: self.modelContext)
            },
            UIAction(title: "Go to Podcast", image: UIImage(systemName: "rectangle.stack")) { [weak self] _ in
                guard let episode = episodeProvider() else { return }
                self?.showPodcast?(episode)
            }
        ])
    }

    private func loadCachedArtifacts() {
        guard let episode = player.currentEpisode else { return }
        transcriptText = LibraryStore.cachedTranscriptText(for: episode, in: modelContext)
        transcriptSegments = LibraryStore.cachedTranscriptSegments(for: episode, in: modelContext)
        Task {
            chapters = await preferredChapters(for: episode)
            player.updateNowPlayingArtwork(url: primaryArtworkURL(for: episode))
            update()
        }
    }

    private func loadArtifacts() async {
        guard let episode = player.currentEpisode else { return }
        if let transcript = try? await client.transcript(for: episode.stableID) {
            await LibraryStore.cacheTranscript(transcript, for: episode, in: modelContext)
            transcriptText = LibraryStore.cachedTranscriptText(for: episode, in: modelContext)
            transcriptSegments = LibraryStore.cachedTranscriptSegments(for: episode, in: modelContext)
        }
        if let artifact = try? await client.chapters(for: episode.stableID) {
            LibraryStore.cacheChapters(artifact, for: episode, in: modelContext)
            chapters = await preferredChapters(for: episode)
        } else {
            chapters = await preferredChapters(for: episode)
        }
        player.updateNowPlayingArtwork(url: primaryArtworkURL(for: episode))
        update()
    }

    private func preferredChapters(for episode: EpisodeDTO) async -> [EpisodeChapterDTO] {
        let embedded = await LibraryStore.embeddedChapters(for: episode, in: modelContext)
        if embedded.count > 1 { return embedded }
        return await LibraryStore.cachedChapters(for: episode, in: modelContext)
    }

    private func currentArtworkURL(for episode: EpisodeDTO) -> URL? {
        chapters
            .last { $0.start <= player.elapsed }
            .flatMap { LibraryStore.cachedChapterImageURL(for: $0, episode: episode, in: modelContext) ?? $0.displayImageURL }
            ?? primaryArtworkURL(for: episode)
    }

    private func primaryArtworkURL(for episode: EpisodeDTO) -> URL? {
        LibraryStore.localArtworkURL(for: episode, in: modelContext)
    }

    private func currentChapterTitle() -> String? {
        guard let chapter = chapters.last(where: { $0.start <= player.elapsed }) else { return nil }
        return chapter.title
    }

    private func podcastTitle(for episode: EpisodeDTO) -> String {
        subscription(for: episode).flatMap { $0.title.isEmpty ? nil : $0.title } ?? "Now Playing"
    }

    private func subscription(for episode: EpisodeDTO) -> PodcastSubscription? {
        guard let podcastStableID = episode.podcastStableID else { return nil }
        let descriptor = FetchDescriptor<PodcastSubscription>(predicate: #Predicate { $0.stableID == podcastStableID })
        return try? modelContext.fetch(descriptor).first
    }

    private func applyPlaybackSettingsIfNeeded(for episode: EpisodeDTO) {
        guard appliedSpeedEpisodeID != episode.stableID else { return }
        appliedSpeedEpisodeID = episode.stableID
        player.speed = Float(PlaybackSettings.speed(for: subscription(for: episode)))
    }

    private var progress: Double {
        guard let duration = player.duration, duration > 0 else { return 0 }
        return min(1, max(0, player.elapsed / duration))
    }

    private var remaining: TimeInterval {
        guard let duration = player.duration else { return 0 }
        return max(0, duration - player.elapsed)
    }

    private func format(_ value: TimeInterval) -> String {
        TimeFormatting.playbackTime(value)
    }

    @objc private func skipBack() {
        player.seek(by: -SeekSettings.backSeconds)
    }

    @objc private func skipForward() {
        player.seek(by: SeekSettings.forwardSeconds)
    }

    @objc private func skipChapterBack() {
        guard !chapters.isEmpty else { return }
        let target = chapters
            .filter { $0.start < player.elapsed - 3 }
            .last?
            .start ?? chapters.first?.start ?? 0
        player.seek(toTime: target)
    }

    @objc private func skipChapterForward() {
        guard !chapters.isEmpty else { return }
        guard let target = chapters.first(where: { $0.start > player.elapsed + 1 })?.start else { return }
        player.seek(toTime: target)
    }

    @objc private func togglePlayback() {
        player.togglePlayPause()
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    @objc private func showCurrentEpisodeDetails() {
        guard let episode = player.currentEpisode else { return }
        showEpisodeDetails?(episode)
    }

    @objc private func showAudioSettings() {
        guard let episode = player.currentEpisode else { return }
        let controller = AudioSettingsViewController(player: player, subscription: subscription(for: episode))
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
        }
        present(controller, animated: true)
    }

    @objc private func showSleepTimer() {
        let alert = UIAlertController(title: "Sleep Timer", message: nil, preferredStyle: .actionSheet)
        ["15 minutes", "30 minutes", "45 minutes", "End of Episode"].forEach { title in
            alert.addAction(UIAlertAction(title: title, style: .default))
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func showTranscriptPanel() {
        displayMode = .transcript
        updateContentMode(animated: true)
    }

    @objc private func showChaptersNotesPanel() {
        displayMode = .chaptersAndNotes
        updateContentMode(animated: true)
    }

    @objc private func handleDismissPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: view)
        switch recognizer.state {
        case .began:
            dragStartY = view.transform.ty
        case .changed:
            view.transform = CGAffineTransform(translationX: 0, y: max(0, dragStartY + translation.y))
        case .ended, .cancelled:
            let velocity = recognizer.velocity(in: view).y
            if translation.y > 120 || velocity > 900 {
                dismiss(animated: true)
            } else {
                UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                    self.view.transform = .identity
                }
            }
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === artworkDismissPan {
            return true
        }
        guard !touch.viewIsDescendant(of: progressControl) else { return false }
        if touch.viewIsDescendant(of: contentContainer) {
            return false
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        if gestureRecognizer === artworkDismissPan {
            return velocity.y > 0 && abs(velocity.y) > abs(velocity.x) * 0.65
        }
        return velocity.y > 0 && abs(velocity.y) > abs(velocity.x) * 0.65
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === artworkDismissPan
            || otherGestureRecognizer === artworkDismissPan
            || gestureRecognizer === contentContainer.panGestureRecognizer
            || otherGestureRecognizer === contentContainer.panGestureRecognizer
    }

}

private final class NowPlayingTranscriptSegmentCell: UITableViewCell {
    static let reuseIdentifier = "NowPlayingTranscriptSegmentCell"

    private let timeLabel = UILabel()
    private let transcriptLabel = UILabel()
    private let container = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectedBackgroundView = UIView()
        selectedBackgroundView?.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.12)

        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = 12
        container.clipsToBounds = true

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .tertiaryLabel
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        transcriptLabel.font = .preferredFont(forTextStyle: .title3)
        transcriptLabel.adjustsFontForContentSizeCategory = true
        transcriptLabel.numberOfLines = 0
        transcriptLabel.textColor = .secondaryLabel

        let row = UIStackView(arrangedSubviews: [timeLabel, transcriptLabel])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10

        contentView.addSubview(container)
        container.addSubview(row)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            timeLabel.widthAnchor.constraint(equalToConstant: 48)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(time: String?, text: String, isCurrent: Bool) {
        timeLabel.text = time ?? "--:--"
        transcriptLabel.text = text
        container.backgroundColor = isCurrent ? UIColor.systemOrange.withAlphaComponent(0.22) : .clear
        timeLabel.textColor = isCurrent ? .systemOrange : .tertiaryLabel
        transcriptLabel.textColor = isCurrent ? .label : .secondaryLabel
        transcriptLabel.font = .preferredFont(forTextStyle: .title3)
    }
}

private final class AudioSettingsViewController: UIViewController {
    private let player: PlayerController
    private let subscription: PodcastSubscription?
    private let speedValueLabel = UILabel()
    private let customSwitch = UISwitch()
    private var customForPodcast: Bool
    private var speed: Double

    init(player: PlayerController, subscription: PodcastSubscription?) {
        self.player = player
        self.subscription = subscription
        self.customForPodcast = PlaybackSettings.usesCustomSpeed(for: subscription)
        self.speed = Double(player.speed)
        super.init(nibName: nil, bundle: nil)
        title = "Audio"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.2, alpha: 1)
        overrideUserInterfaceStyle = .dark
        configureLayout()
        updateSpeed()
    }

    private func configureLayout() {
        let titleLabel = UILabel()
        titleLabel.text = "Audio"
        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true

        let quickRow = UIStackView(arrangedSubviews: [
            quickButton(title: "Normal", speed: 1.0),
            quickButton(title: "2.4x", speed: 2.4),
            quickButton(title: "2.5x", speed: 2.5)
        ])
        quickRow.axis = .horizontal
        quickRow.spacing = 10
        quickRow.distribution = .fillEqually

        speedValueLabel.font = .preferredFont(forTextStyle: .title2)
        speedValueLabel.textColor = .secondaryLabel
        speedValueLabel.textAlignment = .right

        let stepper = UIStepper()
        stepper.minimumValue = 0.5
        stepper.maximumValue = 5
        stepper.stepValue = 0.1
        stepper.value = speed
        stepper.addTarget(self, action: #selector(stepperChanged(_:)), for: .valueChanged)

        let trailing = UIStackView(arrangedSubviews: [speedValueLabel, stepper])
        trailing.axis = .horizontal
        trailing.alignment = .center
        trailing.spacing = 12
        let speedRow = settingsRow(title: "Playback Speed", trailing: trailing)

        let customRow = customPodcastRow()

        let stack = UIStackView(arrangedSubviews: [titleLabel, quickRow, speedRow, customRow])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 18
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 30)
        ])
    }

    private func quickButton(title: String, speed: Double) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.baseBackgroundColor = UIColor.systemOrange.withAlphaComponent(0.28)
        configuration.baseForegroundColor = .systemOrange
        configuration.cornerStyle = .capsule
        let button = UIButton(type: .system)
        button.configuration = configuration
        button.addAction(UIAction { [weak self] _ in self?.setSpeed(speed) }, for: .touchUpInside)
        return button
    }

    private func settingsRow(title: String, trailing: UIView) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true

        let row = UIStackView(arrangedSubviews: [titleLabel, UIView(), trailing])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12

        let container = paddedContainer(row)
        container.heightAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        return container
    }

    private func customPodcastRow() -> UIView {
        let label = UILabel()
        label.text = "Custom for This Podcast"
        label.font = .preferredFont(forTextStyle: .title3)
        label.textColor = subscription == nil ? .secondaryLabel : .label

        customSwitch.isOn = customForPodcast
        customSwitch.isEnabled = subscription != nil
        customSwitch.onTintColor = .systemOrange
        customSwitch.addTarget(self, action: #selector(customChanged), for: .valueChanged)

        let row = UIStackView(arrangedSubviews: [label, UIView(), customSwitch])
        row.axis = .horizontal
        row.alignment = .center
        return paddedContainer(row)
    }

    private func paddedContainer(_ content: UIView) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        container.layer.cornerRadius = 22
        container.clipsToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
        return container
    }

    private func updateSpeed() {
        speed = PlaybackSettings.clampedSpeed(speed)
        speedValueLabel.text = String(format: "%.1fx", speed)
        player.speed = Float(speed)
        PlaybackSettings.setSpeed(speed, for: subscription, customForPodcast: customForPodcast)
    }

    private func setSpeed(_ speed: Double) {
        self.speed = speed
        updateSpeed()
    }

    @objc private func stepperChanged(_ sender: UIStepper) {
        setSpeed(sender.value)
    }

    @objc private func customChanged() {
        customForPodcast = customSwitch.isOn
        PlaybackSettings.setUsesCustomSpeed(customForPodcast, for: subscription, currentSpeed: speed)
        updateSpeed()
    }
}

private final class PlaybackProgressControl: UIControl {
    var valueChanged: ((Double) -> Void)?
    var trackingChanged: ((Bool) -> Void)?

    private var storedValue: Double = 0
    private var isDragging = false
    var value: Double {
        get { storedValue }
        set {
            storedValue = min(1, max(0, newValue))
            setNeedsDisplay()
        }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.45 }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        let trackHeight: CGFloat = isDragging ? 13 : 8
        let thumbDiameter: CGFloat = 0
        let trackRect = CGRect(
            x: thumbDiameter / 2,
            y: (bounds.height - trackHeight) / 2,
            width: max(0, bounds.width - thumbDiameter),
            height: trackHeight
        )
        UIColor.systemOrange.withAlphaComponent(0.26).setFill()
        UIBezierPath(roundedRect: trackRect, cornerRadius: trackHeight / 2).fill()

        let progressWidth = trackRect.width * value
        if progressWidth > 0 {
            let filled = CGRect(x: trackRect.minX, y: trackRect.minY, width: progressWidth, height: trackRect.height)
            UIColor.systemOrange.setFill()
            UIBezierPath(roundedRect: filled, cornerRadius: trackHeight / 2).fill()
        }

    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        isDragging = true
        trackingChanged?(true)
        updateValue(for: touch)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        updateValue(for: touch)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        isDragging = false
        trackingChanged?(false)
        setNeedsDisplay()
    }

    override func cancelTracking(with event: UIEvent?) {
        isDragging = false
        trackingChanged?(false)
        setNeedsDisplay()
    }

    private func updateValue(for touch: UITouch) {
        guard isEnabled else { return }
        let point = touch.location(in: self)
        let inset: CGFloat = 13
        let width = max(1, bounds.width - inset * 2)
        value = Double(min(1, max(0, (point.x - inset) / width)))
        valueChanged?(value)
        sendActions(for: .valueChanged)
    }
}

private extension UITouch {
    func viewIsDescendant(of ancestor: UIView) -> Bool {
        var view = self.view
        while let current = view {
            if current === ancestor { return true }
            view = current.superview
        }
        return false
    }
}
