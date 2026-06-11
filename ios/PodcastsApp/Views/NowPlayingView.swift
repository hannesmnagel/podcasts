import AVKit
import Combine
import SwiftData
import SwiftUI
import UIKit
import WebKit

final class NowPlayingViewController: UIViewController, UIGestureRecognizerDelegate, UIScrollViewDelegate, WKNavigationDelegate, WKScriptMessageHandler {
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
    // Cached per-episode/chapter values — avoids DB queries on every $elapsed tick
    private var cachedPodcastTitleEpisodeID: String?
    private var cachedPodcastTitleValue: String = "Now Playing"
    private var cachedArtworkEpisodeID: String?
    private var cachedArtworkChapterIndex: Int? = nil
    private var cachedArtworkURL: URL?
    private var artifactLoadTask: Task<Void, Never>?
    private var didSetInitialMediaPage = false
    private var hasInteractedWithMediaPager = false
    private var progressSeekStart: TimeInterval?
    private var sleepTimerStatusCancellable: AnyCancellable?
    private var transcriptWebContentLoaded = false
    private var transcriptUserScrollLockUntil = Date.distantPast
    private var transcriptNeedsReload = true
    private var chapterRowViews: [ChapterProgressRowView] = []

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
    private let transcriptWebView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }()
    private let transcriptPlaceholderLabel = UILabel()
    private let alignmentDotView = UIView()
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
    #if targetEnvironment(macCatalyst)
    private var isWindowPinned = false
    private weak var pinButton: UIButton?
    #endif

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
        view.backgroundColor = .systemBackground
        configureLayout()
        configureDismissGesture()
        bindPlayer()
        update()
        Task { @MainActor in
            await Task.yield()
            ensureInitialMediaPage()
        }
        #if targetEnvironment(macCatalyst)
        configureMacOverlayButtons()
        #endif
    }

    #if targetEnvironment(macCatalyst)
    private func configureMacOverlayButtons() {
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 22)

        let closeBtn = UIButton(type: .system)
        closeBtn.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeBtn.tintColor = .secondaryLabel
        closeBtn.setPreferredSymbolConfiguration(symbolConfig, forImageIn: .normal)
        closeBtn.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false

        let pinBtn = UIButton(type: .system)
        pinBtn.setImage(UIImage(systemName: "pin"), for: .normal)
        pinBtn.tintColor = .secondaryLabel
        pinBtn.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 18), forImageIn: .normal)
        pinBtn.accessibilityLabel = "Keep window on top"
        pinBtn.addAction(UIAction { [weak self] _ in self?.toggleWindowPin() }, for: .touchUpInside)
        pinBtn.translatesAutoresizingMaskIntoConstraints = false
        self.pinButton = pinBtn

        view.addSubview(closeBtn)
        view.addSubview(pinBtn)
        NSLayoutConstraint.activate([
            closeBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            pinBtn.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -6),
            pinBtn.centerYAnchor.constraint(equalTo: closeBtn.centerYAnchor)
        ])
    }

    @objc private func toggleWindowPin() {
        isWindowPinned.toggle()
        // NSWindow.Level: normal = 0, floating = 3
        if let nsWindow = view.window?.value(forKey: "nsWindow") as? NSObject {
            nsWindow.setValue(isWindowPinned ? 3 : 0, forKey: "level")
        }
        pinButton?.setImage(UIImage(systemName: isWindowPinned ? "pin.fill" : "pin"), for: .normal)
        pinButton?.tintColor = isWindowPinned ? .systemOrange : .secondaryLabel
    }
    #endif

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

        transcriptWebView.layer.cornerRadius = 20
        transcriptWebView.clipsToBounds = true
        transcriptWebView.navigationDelegate = self
        transcriptWebView.configuration.userContentController.add(self, name: "seekSegment")
        transcriptWebView.scrollView.delegate = self
        transcriptWebView.scrollView.alwaysBounceVertical = true
        transcriptWebView.scrollView.showsVerticalScrollIndicator = false

        transcriptPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false
        transcriptPlaceholderLabel.textColor = .secondaryLabel
        transcriptPlaceholderLabel.font = .preferredFont(forTextStyle: .title3)
        transcriptPlaceholderLabel.adjustsFontForContentSizeCategory = true
        transcriptPlaceholderLabel.numberOfLines = 0
        transcriptPlaceholderLabel.textAlignment = .center
        transcriptPlaceholderLabel.isHidden = true
        transcriptWebView.addSubview(transcriptPlaceholderLabel)
        NSLayoutConstraint.activate([
            transcriptPlaceholderLabel.leadingAnchor.constraint(equalTo: transcriptWebView.leadingAnchor, constant: 16),
            transcriptPlaceholderLabel.trailingAnchor.constraint(equalTo: transcriptWebView.trailingAnchor, constant: -16),
            transcriptPlaceholderLabel.centerYAnchor.constraint(equalTo: transcriptWebView.centerYAnchor)
        ])

        chaptersNotesScrollView.translatesAutoresizingMaskIntoConstraints = false
        chaptersNotesScrollView.backgroundColor = .secondarySystemFill
        chaptersNotesScrollView.layer.cornerRadius = 20
        chaptersNotesScrollView.clipsToBounds = true
        chaptersNotesStack.translatesAutoresizingMaskIntoConstraints = false
        chaptersNotesStack.axis = .vertical
        chaptersNotesStack.spacing = 12
        chaptersNotesStack.isLayoutMarginsRelativeArrangement = true
        chaptersNotesStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)
        chaptersNotesScrollView.addSubview(chaptersNotesStack)
        [transcriptWebView, artworkPage, chaptersNotesScrollView].forEach(mediaPageStack.addArrangedSubview)
        contentContainer.addSubview(mediaPageStack)

        progressControl.translatesAutoresizingMaskIntoConstraints = false
        progressControl.valueChanged = { [weak self] value in
            guard let self else { return }
            self.player.seek(to: value, from: self.progressSeekStart, finalizing: false)
        }
        progressControl.trackingChanged = { [weak self] isTracking in
            if isTracking {
                self?.progressSeekStart = self?.player.elapsed
            } else {
                if let seekStart = self?.progressSeekStart {
                    self?.player.seek(to: self?.progressControl.value ?? 0, from: seekStart, finalizing: true)
                }
                self?.progressSeekStart = nil
            }
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
        [elapsedLabel, remainingLabel].forEach {
            $0.numberOfLines = 1
            $0.adjustsFontSizeToFitWidth = true
            $0.minimumScaleFactor = 0.8
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
            $0.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        let timeSpacer = UIView()
        timeSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let timeRow = UIStackView(arrangedSubviews: [elapsedLabel, timeSpacer, remainingLabel])
        timeRow.translatesAutoresizingMaskIntoConstraints = false
        timeRow.axis = .horizontal
        timeRow.alignment = .center

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

        alignmentDotView.translatesAutoresizingMaskIntoConstraints = false
        alignmentDotView.layer.cornerRadius = 4
        alignmentDotView.isHidden = true
        alignmentDotView.isUserInteractionEnabled = false

        [titleStack, contentContainer, alignmentDotView, progressRow, timeRow, controls, bottom].forEach(view.addSubview)
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
            alignmentDotView.widthAnchor.constraint(equalToConstant: 8),
            alignmentDotView.heightAnchor.constraint(equalToConstant: 8),
            alignmentDotView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -10),
            alignmentDotView.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 10),

            transcriptWebView.widthAnchor.constraint(equalTo: contentContainer.frameLayoutGuide.widthAnchor),
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
            timeRow.topAnchor.constraint(equalTo: progressControl.bottomAnchor, constant: 2),
            timeRow.leadingAnchor.constraint(equalTo: progressControl.leadingAnchor),
            timeRow.trailingAnchor.constraint(equalTo: progressControl.trailingAnchor),
            timeRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
            chapterBackButton.widthAnchor.constraint(equalToConstant: 44),
            chapterBackButton.heightAnchor.constraint(equalToConstant: 44),
            chapterForwardButton.widthAnchor.constraint(equalToConstant: 44),
            chapterForwardButton.heightAnchor.constraint(equalToConstant: 44),

            controls.topAnchor.constraint(equalTo: timeRow.bottomAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 86),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -86),
            controls.bottomAnchor.constraint(lessThanOrEqualTo: bottom.topAnchor, constant: -14),
            playButton.widthAnchor.constraint(equalToConstant: 84),
            playButton.heightAnchor.constraint(equalToConstant: 84),

            bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            bottom.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            bottom.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
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
        timeRow.setContentCompressionResistancePriority(.required, for: .vertical)
        controls.setContentCompressionResistancePriority(.required, for: .vertical)
        bottom.setContentCompressionResistancePriority(.required, for: .vertical)
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
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.clipsToBounds = true
        blur.layer.cornerRadius = cornerRadius
        blur.layer.borderColor = UIColor.separator.cgColor
        blur.layer.borderWidth = 1
        return blur
    }

    private func bindPlayer() {
        player.$currentEpisode
            .map { $0?.stableID }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadArtifactsForCurrentEpisode()
            }
            .store(in: &cancellables)

        player.$currentEpisode.combineLatest(player.$isPlaying, player.$elapsed, player.$duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in self?.update() }
            .store(in: &cancellables)
        player.$speed.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.update() }.store(in: &cancellables)
        SleepTimerState.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateSleepTimerUI() }
            .store(in: &cancellables)
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
        if cachedPodcastTitleEpisodeID != episode.stableID {
            cachedPodcastTitleEpisodeID = episode.stableID
            cachedPodcastTitleValue = podcastTitle(for: episode)
        }
        podcastLabel.text = cachedPodcastTitleValue.uppercased()
        dateLabel.text = episode.publishedAt?.formatted(date: .abbreviated, time: .omitted)
        let chapterIdx = chapters.isEmpty ? nil : chapters.lastIndex { $0.start <= player.elapsed }
        if cachedArtworkEpisodeID != episode.stableID || cachedArtworkChapterIndex != chapterIdx {
            cachedArtworkEpisodeID = episode.stableID
            cachedArtworkChapterIndex = chapterIdx
            cachedArtworkURL = currentArtworkURL(for: episode)
        }
        artworkView.load(url: cachedArtworkURL, minimumPixelDimension: 1200)
        currentChapterLabel.text = currentChapterTitle()
        updateSwipePanelsIfNeeded(for: episode)
        updateTranscriptPlaybackPosition()
        playButton.setImage(UIImage(systemName: player.isPlaying ? "pause.fill" : "play.fill"), for: .normal)
        progressControl.isEnabled = player.duration != nil
        progressControl.value = progress
        updateChapterSkipButtons()
        updateChapterRowProgress()
        elapsedLabel.text = format(player.elapsed)
        remainingLabel.text = "-\(format(remaining))"
        handleSleepTimerIfNeeded()
        updateSleepTimerUI()
    }

    private func updateChapterSkipButtons() {
        let hasChapters = chapters.count > 1
        chapterBackButton.isEnabled = hasChapters
        chapterForwardButton.isEnabled = hasChapters
        chapterBackButton.alpha = hasChapters ? 1 : 0.35
        chapterForwardButton.alpha = hasChapters ? 1 : 0.35
    }

    private func updateSwipePanelsIfNeeded(for episode: EpisodeDTO) {
        let cacheKey = "\(episode.stableID):\(transcriptSegments.count):\(transcriptText?.count ?? 0):\(chapters.count):\(ChapterSkipRuleStore.rules.count):\(episode.summary?.count ?? 0)"
        guard cacheKey != swipePanelCacheKey else { return }
        swipePanelCacheKey = cacheKey
        rebuildTranscriptPanel()
        rebuildChaptersNotes(for: episode)
    }

    private func rebuildTranscriptPanel() {
        currentTranscriptSegmentIndex = nil
        transcriptWebContentLoaded = false
        transcriptNeedsReload = true

        guard !transcriptSegments.isEmpty else {
            let text = transcriptText?.isEmpty == false ? transcriptText! : "No transcript yet."
            transcriptPlaceholderLabel.text = text
            transcriptPlaceholderLabel.isHidden = false
            return
        }

        transcriptPlaceholderLabel.text = nil
        transcriptPlaceholderLabel.isHidden = true
        loadTranscriptIfNeeded()
    }

    private func loadTranscriptIfNeeded(force: Bool = false) {
        guard force || transcriptNeedsReload else { return }
        transcriptNeedsReload = false
        transcriptWebContentLoaded = false
        let segments = transcriptSegments
        Task {
            let html = await Self.buildTranscriptHTML(segments: segments)
            guard self.transcriptSegments.count == segments.count else { return }
            self.transcriptWebView.loadHTMLString(html, baseURL: nil)
        }
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

    private func applyTranscriptHighlight(previousIndex _: Int? = nil, scroll: Bool) {
        guard !transcriptSegments.isEmpty else { return }
        guard let currentTranscriptSegmentIndex, transcriptWebContentLoaded else { return }
        let allowScroll = scroll && Date() >= transcriptUserScrollLockUntil
        transcriptWebView.evaluateJavaScript("window.podcatcherSetCurrentSegment(\(currentTranscriptSegmentIndex), \(allowScroll ? "true" : "false"));", completionHandler: nil)
    }

    @concurrent
    private static func buildTranscriptHTML(segments: [TranscriptSegment]) async -> String {
        guard !segments.isEmpty else {
            return "<!doctype html><html><body style=\"margin:0;background:transparent;\"></body></html>"
        }
        let rows = segments.enumerated().map { index, segment in
            let timeText = segment.start.map { transcriptFormatTime($0) } ?? segment.originalStart.map { "~\(transcriptFormatTime($0))" } ?? ""
            let insertedClass = segment.isInsertedAudio ? " inserted" : ""
            let prefix = segment.isInsertedAudio ? "Inserted audio / not in transcript " : ""
            let normalized = normalizeTranscriptDisplayText(prefix + segment.text)
            return """
            <div class="row\(insertedClass)" id="segment-\(index)" data-index="\(index)" data-seekable="\(segment.isInsertedAudio ? "false" : "true")">
              <span class="time">\(escapeHTML(timeText))</span>
              <span class="text">\(escapeHTML(normalized))</span>
            </div>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline';">
          <style>
            :root {
              --c-bg: rgba(255,255,255,0.06);
              --c-text: rgba(255,255,255,0.92);
              --c-time: rgba(255,255,255,0.42);
              --c-body: rgba(255,255,255,0.80);
            }
            @media (prefers-color-scheme: light) {
              :root {
                --c-bg: rgba(0,0,0,0.03);
                --c-text: rgba(0,0,0,0.88);
                --c-time: rgba(0,0,0,0.40);
                --c-body: rgba(0,0,0,0.75);
              }
            }
            body { margin:0; padding:12px 14px; font: -apple-system-body; background: var(--c-bg); color: var(--c-text); -webkit-user-select:text; user-select:text; }
            .row { display:block; color:inherit; padding:6px 10px; border-radius:10px; }
            .time { display:block; margin:0 0 3px 0; font: 600 11px ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--c-time); letter-spacing: 0.2px; -webkit-user-select:none; user-select:none; }
            .text { display:block; color: var(--c-body); line-height:1.24; white-space:normal; word-break:break-word; }
            .row.current { background: rgba(255,149,0,0.18); }
            .row.current .time { color: rgba(255,149,0,1); }
            .row.inserted .time, .row.inserted .text { color: rgba(191,90,242,0.9); }
          </style>
          <script>
            let currentIndex = null;
            window.podcatcherSetCurrentSegment = function(index, allowScroll) {
              const previous = currentIndex === null ? null : document.getElementById('segment-' + currentIndex);
              if (previous) previous.classList.remove('current');
              const current = document.getElementById('segment-' + index);
              if (!current) return;
              current.classList.add('current');
              currentIndex = index;
              if (!allowScroll) return;
              const viewportHeight = document.documentElement.clientHeight;
              const target = current.offsetTop + (current.offsetHeight / 2) - (viewportHeight / 2);
              const rowCenter = current.getBoundingClientRect().top + current.offsetHeight / 2;
              const viewCenter = viewportHeight / 2;
              if (Math.abs(rowCenter - viewCenter) > current.offsetHeight * 0.5) {
                window.scrollTo({ top: Math.max(0, target), behavior: 'smooth' });
              }
            };
            document.addEventListener('click', function(event) {
              const row = event.target.closest('.row');
              if (!row || row.dataset.seekable !== 'true') return;
              const selected = window.getSelection ? window.getSelection().toString().trim() : '';
              if (selected.length > 0) return;
              const index = parseInt(row.dataset.index || '', 10);
              if (Number.isNaN(index)) return;
              window.webkit.messageHandlers.seekSegment.postMessage(index);
            }, true);
          </script>
        </head>
        <body>\(rows)</body>
        </html>
        """
    }

    private nonisolated static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private nonisolated static func normalizeTranscriptDisplayText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func transcriptFormatTime(_ value: TimeInterval) -> String {
        TimeFormatting.playbackTime(value)
    }

    private func rebuildChaptersNotes(for episode: EpisodeDTO) {
        chapterRowViews = []
        chaptersNotesStack.arrangedSubviews.forEach { view in
            chaptersNotesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let chaptersTitle = panelTitle("Chapters")
        chaptersNotesStack.addArrangedSubview(chaptersTitle)

        if chapters.isEmpty {
            chaptersNotesStack.addArrangedSubview(panelBody("No chapters yet."))
        } else {
            chapters.enumerated().forEach { index, chapter in
                let row = chapterRow(for: chapter, at: index)
                chapterRowViews.append(row)
                chaptersNotesStack.addArrangedSubview(row)
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
        updateChapterRowProgress()
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

    private func chapterRow(for chapter: EpisodeChapterDTO, at index: Int) -> ChapterProgressRowView {
        let row = ChapterProgressRowView()
        row.configure(title: chapter.title, timeText: format(chapter.start))
        row.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.player.seek(toTime: chapter.start)
            if let current = self.player.currentEpisode {
                self.player.updateNowPlayingArtwork(
                    url: LibraryStore.cachedChapterImageURL(for: chapter, episode: current, in: self.modelContext)
                        ?? chapter.displayImageURL
                        ?? self.currentArtworkURL(for: current)
                )
            }
        }, for: .touchUpInside)
        let skipState: UIMenuElement.State = ChapterSkipRuleStore.shouldSkip(chapterTitle: chapter.title) ? .on : .off
        row.menu = UIMenu(children: [
            UIAction(title: "Always Skip ‘\(chapter.title)’", image: UIImage(systemName: "forward.end.fill"), state: skipState) { [weak self] _ in
                ChapterSkipRuleStore.addExactTitle(chapter.title)
                self?.swipePanelCacheKey = nil
                self?.update()
            }
        ])
        row.showsMenuAsPrimaryAction = false
        row.chapterIndex = index
        return row
    }

    private func updateChapterRowProgress() {
        guard !chapterRowViews.isEmpty else { return }
        let elapsed = player.elapsed
        for row in chapterRowViews {
            guard chapters.indices.contains(row.chapterIndex) else { continue }
            let chapter = chapters[row.chapterIndex]
            let chapterStart = chapter.start
            let chapterEnd = chapter.end
                ?? (chapters.indices.contains(row.chapterIndex + 1) ? chapters[row.chapterIndex + 1].start : (player.duration ?? chapter.start))
            let duration = max(0.001, chapterEnd - chapterStart)
            let progress = max(0, min(1, (elapsed - chapterStart) / duration))
            let isCurrent = elapsed >= chapterStart && elapsed < chapterEnd
            row.updateProgress(progress, isCurrent: isCurrent)
        }
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
            loadTranscriptIfNeeded()
            applyTranscriptHighlight(scroll: true)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if scrollView === contentContainer {
            updateDisplayModeForCurrentPage()
            return
        }
        if scrollView === transcriptWebView.scrollView {
            transcriptUserScrollLockUntil = Date().addingTimeInterval(4)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollView === contentContainer {
            hasInteractedWithMediaPager = true
            return
        }
        if scrollView === transcriptWebView.scrollView {
            transcriptUserScrollLockUntil = Date().addingTimeInterval(4)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if scrollView === contentContainer {
            if !decelerate {
                updateDisplayModeForCurrentPage()
            }
            return
        }
        if scrollView === transcriptWebView.scrollView, !decelerate {
            transcriptUserScrollLockUntil = Date().addingTimeInterval(4)
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView === contentContainer else { return }
        updateDisplayModeForCurrentPage()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === transcriptWebView.scrollView,
           (scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating) {
            transcriptUserScrollLockUntil = Date().addingTimeInterval(4)
        }
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
            loadTranscriptIfNeeded()
            applyTranscriptHighlight(scroll: true)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === transcriptWebView else { return }
        transcriptWebContentLoaded = true
        applyTranscriptHighlight(scroll: displayMode == .transcript)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === transcriptWebView else { return }
        transcriptNeedsReload = true
        loadTranscriptIfNeeded(force: true)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "seekSegment",
              let index = message.body as? Int,
              transcriptSegments.indices.contains(index),
              !transcriptSegments[index].isInsertedAudio,
              let start = transcriptSegments[index].start else { return }
        currentTranscriptSegmentIndex = index
        applyTranscriptHighlight(scroll: false)
        player.seek(toTime: start)
    }

    @MainActor
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard webView === transcriptWebView, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme ?? ""
        if scheme == "about" || scheme == "data" || scheme == "blob" {
            decisionHandler(.allow)
            return
        }
        // Allow normal internal/document navigations. External loads remain blocked.
        if navigationAction.navigationType == .other,
           navigationAction.targetFrame?.isMainFrame != false {
            decisionHandler(.allow)
            return
        }
        guard scheme == "podcatcher",
              url.host == "segment",
              let index = Int(url.lastPathComponent),
              transcriptSegments.indices.contains(index),
              !transcriptSegments[index].isInsertedAudio,
              let start = transcriptSegments[index].start else {
            decisionHandler(.cancel)
            return
        }
        currentTranscriptSegmentIndex = index
        applyTranscriptHighlight(scroll: false)
        player.seek(toTime: start)
        decisionHandler(.cancel)
    }

    private func makeMenu() -> UIMenu {
        let episodeProvider = { [weak self] in self?.player.currentEpisode }
        var children: [UIMenuElement] = [
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
                self.presentPodcastShareOptions(for: episode, in: self.modelContext)
            },
            UIAction(title: "Remove Download", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                guard let self, let episode = episodeProvider() else { return }
                LibraryStore.removeDownload(for: episode, in: self.modelContext)
            },
            UIAction(title: "Go to Podcast", image: UIImage(systemName: "rectangle.stack")) { [weak self] _ in
                guard let episode = episodeProvider() else { return }
                self?.showPodcast?(episode)
            }
        ]
        if let currentTitle = currentChapterTitle() {
            children.append(UIAction(title: "Always Skip Current Chapter", subtitle: currentTitle, image: UIImage(systemName: "forward.end.fill")) { [weak self] _ in
                ChapterSkipRuleStore.addExactTitle(currentTitle)
                self?.swipePanelCacheKey = nil
                self?.update()
            })
        }
        children.append(UIAction(title: "Add Chapter Skip Regex…", image: UIImage(systemName: "text.magnifyingglass")) { [weak self] _ in
            self?.showAddChapterSkipRegex()
        })
        if !ChapterSkipRuleStore.rules.isEmpty {
            children.append(UIAction(title: "Clear Chapter Skip Rules", image: UIImage(systemName: "xmark.circle"), attributes: .destructive) { [weak self] _ in
                ChapterSkipRuleStore.removeAll()
                self?.swipePanelCacheKey = nil
                self?.update()
            })
        }
        return UIMenu(children: children)
    }

    private func reloadArtifactsForCurrentEpisode() {
        artifactLoadTask?.cancel()
        transcriptText = nil
        transcriptSegments = []
        currentTranscriptSegmentIndex = nil
        chapters = []
        swipePanelCacheKey = nil
        alignmentDotView.isHidden = true
        player.updateAutoSkipChapters([])

        guard let episode = player.currentEpisode else {
            update()
            return
        }

        loadCachedArtifacts(for: episode)
        artifactLoadTask = Task { @MainActor [weak self, episode] in
            await self?.loadArtifacts(for: episode)
        }
        update()
    }

    private func loadCachedArtifacts(for episode: EpisodeDTO) {
        guard isCurrentEpisode(episode) else { return }
        transcriptText = LibraryStore.cachedTranscriptText(for: episode, in: modelContext)
        transcriptSegments = LibraryStore.cachedTranscriptSegments(for: episode, in: modelContext)
        updateAlignmentDot(for: episode)
        Task { @MainActor [weak self, episode] in
            guard let self else { return }
            let loadedChapters = await preferredChapters(for: episode)
            guard !Task.isCancelled, self.isCurrentEpisode(episode) else { return }
            self.chapters = loadedChapters
            self.player.updateAutoSkipChapters(loadedChapters)
            self.player.updateNowPlayingArtwork(url: self.currentArtworkURL(for: episode))
            self.update()
        }
    }

    private func updateAlignmentDot(for episode: EpisodeDTO) {
        guard isCurrentEpisode(episode) else { return }
        switch LibraryStore.transcriptAlignmentStatus(for: episode, in: modelContext) {
        case .none:
            alignmentDotView.isHidden = true
        case .exactFile:
            alignmentDotView.backgroundColor = .systemGreen
            alignmentDotView.isHidden = false
        case .extrapolated:
            alignmentDotView.backgroundColor = .systemYellow
            alignmentDotView.isHidden = false
        }
    }

    private func loadArtifacts(for episode: EpisodeDTO) async {
        guard isCurrentEpisode(episode) else { return }
        if let transcript = try? await client.transcript(for: episode.stableID) {
            guard !Task.isCancelled, isCurrentEpisode(episode) else { return }
            await LibraryStore.cacheTranscript(transcript, for: episode, in: modelContext)
            if let fingerprint = try? await client.fingerprint(for: episode.stableID) {
                guard !Task.isCancelled, isCurrentEpisode(episode) else { return }
                LibraryStore.cacheFingerprint(fingerprint, for: episode, in: modelContext)
                await LibraryStore.alignTranscriptToDownloadedAudio(for: episode, in: modelContext)
                updateAlignmentDot(for: episode)
            }
            guard !Task.isCancelled, isCurrentEpisode(episode) else { return }
            transcriptText = LibraryStore.cachedTranscriptText(for: episode, in: modelContext)
            transcriptSegments = LibraryStore.cachedTranscriptSegments(for: episode, in: modelContext)
        }
        if let artifact = try? await client.chapters(for: episode.stableID) {
            guard !Task.isCancelled, isCurrentEpisode(episode) else { return }
            LibraryStore.cacheChapters(artifact, for: episode, in: modelContext)
            let loadedChapters = await preferredChapters(for: episode)
            guard !Task.isCancelled, isCurrentEpisode(episode) else { return }
            chapters = loadedChapters
        } else {
            let loadedChapters = await preferredChapters(for: episode)
            guard !Task.isCancelled, isCurrentEpisode(episode) else { return }
            chapters = loadedChapters
        }
        player.updateAutoSkipChapters(chapters)
        player.updateNowPlayingArtwork(url: currentArtworkURL(for: episode))
        update()
    }

    private func isCurrentEpisode(_ episode: EpisodeDTO) -> Bool {
        player.currentEpisode?.stableID == episode.stableID
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
        #if targetEnvironment(macCatalyst)
        if let scene = view.window?.windowScene {
            UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil, errorHandler: nil)
        } else {
            dismiss(animated: true)
        }
        #else
        dismiss(animated: true)
        #endif
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))]
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
        let controller = SleepTimerViewController(player: player)
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
        }
        present(controller, animated: true)
    }

    private func handleSleepTimerIfNeeded() {
        guard let state = SleepTimerState.shared.state else { return }
        if state.mode == .endOfEpisode, remaining <= 0.75 {
            player.pauseForSleepTimer()
            SleepTimerState.shared.clear()
        }
    }


    private func formatAudioTime(_ t: Double) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func updateSleepTimerUI() {
        // Hook for future icon state updates in now playing controls.
    }

    private func showAddChapterSkipRegex() {
        let alert = UIAlertController(title: "Skip Chapter Regex", message: "Skip future chapters whose title matches this regular expression.", preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "e.g. (?i)ads?|sponsor"
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let pattern = alert?.textFields?.first?.text,
                  ChapterSkipRuleStore.addRegex(pattern) else {
                self?.showErrorMessage("Invalid regular expression")
                return
            }
            self.swipePanelCacheKey = nil
            self.update()
        })
        present(alert, animated: true)
    }

    private func showErrorMessage(_ message: String) {
        let alert = UIAlertController(title: "Couldn’t Add Rule", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func showDownloadFailed() {
        guard let episode = player.currentEpisode else { return }
        FloatingDownloadHUD.shared.showFailure(progressID: episode.stableID, title: episode.title)
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

private final class ChapterProgressRowView: UIButton {
    var chapterIndex: Int = 0

    private let fillView = UIView()
    private let fillWidthConstraint: NSLayoutConstraint
    private let timeLabel = UILabel()
    private let titleLabelView = UILabel()
    private var backgroundLeadingConstraint: NSLayoutConstraint?
    private var cachedBoundsWidth: CGFloat = 0

    override init(frame: CGRect) {
        fillWidthConstraint = fillView.widthAnchor.constraint(equalToConstant: 0)
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 10
        clipsToBounds = true
        backgroundColor = .secondarySystemFill
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.cgColor
        contentHorizontalAlignment = .leading

        fillView.translatesAutoresizingMaskIntoConstraints = false
        fillView.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.32)
        addSubview(fillView)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        timeLabel.textColor = .secondaryLabel
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabelView.translatesAutoresizingMaskIntoConstraints = false
        titleLabelView.font = .preferredFont(forTextStyle: .subheadline)
        titleLabelView.adjustsFontForContentSizeCategory = true
        titleLabelView.textColor = .label
        titleLabelView.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [timeLabel, titleLabelView])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        addSubview(stack)

        NSLayoutConstraint.activate([
            fillView.leadingAnchor.constraint(equalTo: leadingAnchor),
            fillView.topAnchor.constraint(equalTo: topAnchor),
            fillView.bottomAnchor.constraint(equalTo: bottomAnchor),
            fillWidthConstraint,

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != cachedBoundsWidth {
            cachedBoundsWidth = bounds.width
            fillWidthConstraint.constant = fillWidthConstraint.constant
        }
    }

    func configure(title: String, timeText: String) {
        titleLabelView.text = title
        timeLabel.text = timeText
    }

    func updateProgress(_ progress: Double, isCurrent: Bool) {
        let clamped = max(0, min(1, progress))
        fillWidthConstraint.constant = bounds.width * clamped
        layer.borderColor = (isCurrent ? UIColor.systemOrange : UIColor.separator).cgColor
        UIView.animate(withDuration: 0.2) {
            self.layoutIfNeeded()
        }
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
        view.backgroundColor = .secondarySystemBackground
        configureLayout()
        updateSpeed()
        let closeBtn = UIButton(type: .system)
        closeBtn.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeBtn.tintColor = .secondaryLabel
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        closeBtn.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 24), forImageIn: .normal)
        view.addSubview(closeBtn)
        NSLayoutConstraint.activate([
            closeBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            closeBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12)
        ])
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
        container.backgroundColor = .secondarySystemFill
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
        if !customForPodcast {
            speed = PlaybackSettings.globalSpeed
        }
        PlaybackSettings.setUsesCustomSpeed(customForPodcast, for: subscription, currentSpeed: speed)
        updateSpeed()
    }
}

private final class SleepTimerViewController: UIHostingController<SleepTimerSheet> {
    init(player: PlayerController) {
        super.init(rootView: SleepTimerSheet(player: player))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct SleepTimerSheet: View {
    let player: PlayerController
    @ObservedObject private var timerState = SleepTimerState.shared
    @State private var now = Date()
    @Environment(\.dismiss) private var dismiss

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Sleep Timer")
                    .font(.title2.bold())
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.top)

            statusSection
                .padding(.horizontal)

            Divider()
                .padding(.vertical, 4)

            optionsSection
                .padding(.horizontal)

            Spacer()
        }
        .onReceive(ticker) { date in
            now = date
            checkExpiry()
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let state = timerState.state {
            HStack {
                ZStack {
                    Circle()
                        .stroke(Color.orange.opacity(0.2), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: progress(for: state))
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: progress(for: state))
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading) {
                    Text(statusTitle(for: state))
                        .font(.subheadline.bold())
                    Text(statusSubtitle(for: state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(role: .destructive) {
                    SleepTimerState.shared.clear()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Cancel sleep timer")
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        } else {
            HStack {
                Image(systemName: "moon.zzz")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("No active timer")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var optionsSection: some View {
        VStack {
            timerRow(label: "15 minutes", icon: "moon") { SleepTimerState.shared.start(minutes: 15) }
            timerRow(label: "30 minutes", icon: "moon.fill") { SleepTimerState.shared.start(minutes: 30) }
            timerRow(label: "45 minutes", icon: "moon.stars") { SleepTimerState.shared.start(minutes: 45) }
            timerRow(label: "End of episode", icon: "flag") { SleepTimerState.shared.startEndOfEpisode() }
        }
    }

    private func timerRow(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func progress(for state: SleepTimerState.State) -> CGFloat {
        switch state.mode {
        case .fixedDuration:
            let remaining = max(0, state.endDate.timeIntervalSince(now))
            return CGFloat(max(0, min(1, 1 - (remaining / state.duration))))
        case .endOfEpisode:
            let duration = max(player.duration ?? 0, 0)
            return duration > 0 ? CGFloat(min(1, max(0, player.elapsed / duration))) : 0
        }
    }

    private func statusTitle(for state: SleepTimerState.State) -> String {
        switch state.mode {
        case .fixedDuration:
            let remaining = max(0, state.endDate.timeIntervalSince(now))
            let m = Int(remaining / 60)
            let s = Int(remaining) % 60
            return "\(m)m \(s)s remaining"
        case .endOfEpisode:
            return "Until episode ends"
        }
    }

    private func statusSubtitle(for state: SleepTimerState.State) -> String {
        switch state.mode {
        case .fixedDuration: return "Fixed duration"
        case .endOfEpisode: return "Tracking episode progress"
        }
    }

    private func checkExpiry() {
        guard let state = timerState.state, state.mode == .fixedDuration else { return }
        if state.endDate.timeIntervalSince(now) <= 0.5 {
            player.pauseForSleepTimer()
            SleepTimerState.shared.clear()
        }
    }
}

@MainActor
private final class SleepTimerState: ObservableObject {
    enum Mode {
        case fixedDuration
        case endOfEpisode
    }

    struct State {
        let mode: Mode
        let startedAt: Date
        let endDate: Date
        let duration: TimeInterval
    }

    static let shared = SleepTimerState()
    @Published private(set) var state: State?

    func start(minutes: Double) {
        let duration = minutes * 60
        let now = Date()
        state = State(mode: .fixedDuration, startedAt: now, endDate: now.addingTimeInterval(duration), duration: duration)
    }

    func startEndOfEpisode() {
        let now = Date()
        state = State(mode: .endOfEpisode, startedAt: now, endDate: now, duration: 1)
    }

    func clear() {
        state = nil
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
