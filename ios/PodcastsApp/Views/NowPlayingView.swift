import AVKit
import Combine
import SwiftData
import UIKit

final class NowPlayingViewController: UIViewController {
    private let modelContext: ModelContext
    private let player: PlayerController
    private let client = BackendClient()
    private var cancellables: Set<AnyCancellable> = []
    private var transcriptText: String?
    private var chapters: [EpisodeChapterDTO] = []

    var showEpisodeDetails: ((EpisodeDTO) -> Void)?
    var showPodcast: ((EpisodeDTO) -> Void)?

    private let titleLabel = UILabel()
    private let dateLabel = UILabel()
    private let artworkView = ArtworkImageView(cornerRadius: 20)
    private let progressSlider = UISlider()
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let speedButton = UIButton(type: .system)

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
        bindPlayer()
        update()
        Task {
            loadCachedArtifacts()
            await loadArtifacts()
        }
    }

    private func configureLayout() {
        let grabber = UIView()
        grabber.translatesAutoresizingMaskIntoConstraints = false
        grabber.backgroundColor = .secondaryLabel
        grabber.layer.cornerRadius = 2.5
        view.addSubview(grabber)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 2
        dateLabel.font = .preferredFont(forTextStyle: .subheadline)
        dateLabel.textColor = .secondaryLabel

        let topMenuButton = menuButton()

        let header = UIStackView(arrangedSubviews: [titleLabel, topMenuButton])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.alignment = .top
        header.spacing = 12
        let titleStack = UIStackView(arrangedSubviews: [header, dateLabel])
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.axis = .vertical
        titleStack.spacing = 4

        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.tintColor = .systemOrange
        progressSlider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        remainingLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        elapsedLabel.textColor = .secondaryLabel
        remainingLabel.textColor = .secondaryLabel

        let timeRow = UIStackView(arrangedSubviews: [elapsedLabel, UIView(), remainingLabel])
        timeRow.translatesAutoresizingMaskIntoConstraints = false
        timeRow.axis = .horizontal

        let backButton = controlButton(systemName: "gobackward.15", action: #selector(skipBack))
        playButton.tintColor = .systemOrange
        playButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        let forwardButton = controlButton(systemName: "goforward.30", action: #selector(skipForward))
        let controls = UIStackView(arrangedSubviews: [backButton, playButton, forwardButton])
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.distribution = .equalCentering
        controls.alignment = .center

        let closeButton = controlButton(systemName: "chevron.down", action: #selector(close))
        speedButton.setTitleColor(.label, for: .normal)
        speedButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        speedButton.addTarget(self, action: #selector(showSpeedPicker), for: .touchUpInside)
        let routePicker = AVRoutePickerView()
        routePicker.translatesAutoresizingMaskIntoConstraints = false
        routePicker.activeTintColor = .label
        routePicker.tintColor = .label

        let bottom = UIStackView(arrangedSubviews: [closeButton, speedButton, routePicker, menuButton()])
        bottom.translatesAutoresizingMaskIntoConstraints = false
        bottom.distribution = .equalCentering
        bottom.alignment = .center

        [titleStack, artworkView, progressSlider, timeRow, controls, bottom].forEach(view.addSubview)
        NSLayoutConstraint.activate([
            grabber.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            grabber.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 36),
            grabber.heightAnchor.constraint(equalToConstant: 5),

            titleStack.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: 24),
            titleStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            artworkView.topAnchor.constraint(equalTo: titleStack.bottomAnchor, constant: 28),
            artworkView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            artworkView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.78),
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),

            progressSlider.topAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: 30),
            progressSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            progressSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            timeRow.topAnchor.constraint(equalTo: progressSlider.bottomAnchor, constant: 4),
            timeRow.leadingAnchor.constraint(equalTo: progressSlider.leadingAnchor),
            timeRow.trailingAnchor.constraint(equalTo: progressSlider.trailingAnchor),

            controls.topAnchor.constraint(equalTo: timeRow.bottomAnchor, constant: 24),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 72),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -72),
            playButton.widthAnchor.constraint(equalToConstant: 76),
            playButton.heightAnchor.constraint(equalToConstant: 76),

            bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            bottom.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            bottom.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            routePicker.widthAnchor.constraint(equalToConstant: 44),
            routePicker.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func controlButton(systemName: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = .systemOrange
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 56),
            button.heightAnchor.constraint(equalToConstant: 56)
        ])
        return button
    }

    private func menuButton() -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        button.tintColor = .label
        button.menu = makeMenu()
        button.showsMenuAsPrimaryAction = true
        return button
    }

    private func bindPlayer() {
        player.$currentEpisode.combineLatest(player.$isPlaying, player.$elapsed, player.$duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in self?.update() }
            .store(in: &cancellables)
        player.$speed.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.update() }.store(in: &cancellables)
    }

    private func update() {
        guard let episode = player.currentEpisode else {
            titleLabel.text = "Nothing Playing"
            return
        }
        titleLabel.text = episode.title
        dateLabel.text = episode.publishedAt?.formatted(date: .abbreviated, time: .omitted)
        artworkView.load(url: currentArtworkURL(for: episode))
        playButton.setImage(UIImage(systemName: player.isPlaying ? "pause.fill" : "play.fill"), for: .normal)
        progressSlider.isEnabled = player.duration != nil
        progressSlider.value = Float(progress)
        elapsedLabel.text = format(player.elapsed)
        remainingLabel.text = "-\(format(remaining))"
        speedButton.setTitle(String(format: "%.2g×", player.speed), for: .normal)
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
            UIAction(title: "Delete Episode", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                guard let self, let episode = episodeProvider() else { return }
                LibraryStore.markDeleted(episode, in: self.modelContext)
                self.dismiss(animated: true)
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
        Task {
            chapters = await LibraryStore.cachedChapters(for: episode, in: modelContext)
            player.updateNowPlayingArtwork(url: currentArtworkURL(for: episode))
            update()
        }
    }

    private func loadArtifacts() async {
        guard let episode = player.currentEpisode else { return }
        if let transcript = try? await client.transcript(for: episode.stableID) {
            await LibraryStore.cacheTranscript(transcript, for: episode, in: modelContext)
            transcriptText = LibraryStore.cachedTranscriptText(for: episode, in: modelContext)
        }
        if let artifact = try? await client.chapters(for: episode.stableID) {
            LibraryStore.cacheChapters(artifact, for: episode, in: modelContext)
            chapters = await ArtifactDataProcessor.renderChapters(chaptersJSON: artifact.chaptersJSON)
        } else {
            chapters = await LibraryStore.cachedChapters(for: episode, in: modelContext)
        }
        player.updateNowPlayingArtwork(url: currentArtworkURL(for: episode))
        update()
    }

    private func currentArtworkURL(for episode: EpisodeDTO) -> URL? {
        chapters
            .last { $0.start <= player.elapsed }
            .flatMap { LibraryStore.cachedChapterImageURL(for: $0, episode: episode, in: modelContext) ?? $0.displayImageURL }
            ?? LibraryStore.localArtworkURL(for: episode, in: modelContext)
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
        guard value.isFinite else { return "--:--" }
        let total = max(0, Int(value.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? "\(h):" + String(format: "%02d:%02d", m, s) : "\(m):" + String(format: "%02d", s)
    }

    @objc private func sliderChanged() {
        player.seek(to: Double(progressSlider.value))
    }

    @objc private func skipBack() {
        player.seek(by: -15)
    }

    @objc private func skipForward() {
        player.seek(by: 30)
    }

    @objc private func togglePlayback() {
        player.togglePlayPause()
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    @objc private func showSpeedPicker() {
        let alert = UIAlertController(title: "Playback Speed", message: nil, preferredStyle: .actionSheet)
        [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0].forEach { speed in
            alert.addAction(UIAlertAction(title: String(format: "%.2g×", speed), style: .default) { [weak self] _ in
                self?.player.speed = Float(speed)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}
