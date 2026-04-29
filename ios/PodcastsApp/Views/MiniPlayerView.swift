import Combine
import SwiftData
import UIKit

final class MiniPlayerView: UIControl {
    private let modelContext: ModelContext
    private let player: PlayerController
    private var cancellables: Set<AnyCancellable> = []

    private let artworkView = ArtworkImageView(cornerRadius: 8)
    private let titleLabel = UILabel()
    private let playButton = UIButton(type: .system)

    var openNowPlaying: (() -> Void)?

    init(modelContext: ModelContext, player: PlayerController) {
        self.modelContext = modelContext
        self.player = player
        super.init(frame: .zero)
        configure()
        bindPlayer()
        update()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 60)
    }

    private func configure() {
        backgroundColor = .secondarySystemBackground
        layer.borderColor = UIColor.separator.cgColor
        layer.borderWidth = 0.5

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1

        playButton.tintColor = .systemOrange
        playButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)

        [artworkView, titleLabel, playButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = true
            addSubview($0)
        }

        addTarget(self, action: #selector(open), for: .touchUpInside)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = bounds.insetBy(dx: 16, dy: 8)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let artworkSide = min(44, bounds.height)
        let controlSide = min(44, bounds.height)
        let spacing: CGFloat = 12
        let centerY = bounds.midY

        artworkView.frame = CGRect(
            x: bounds.minX,
            y: centerY - artworkSide / 2,
            width: artworkSide,
            height: artworkSide
        )
        playButton.frame = CGRect(
            x: bounds.maxX - controlSide,
            y: centerY - controlSide / 2,
            width: controlSide,
            height: controlSide
        )
        let titleX = artworkView.frame.maxX + spacing
        let titleMaxX = playButton.frame.minX - spacing
        titleLabel.frame = CGRect(
            x: titleX,
            y: bounds.minY,
            width: max(0, titleMaxX - titleX),
            height: bounds.height
        )
    }

    private func bindPlayer() {
        player.$currentEpisode
            .combineLatest(player.$isPlaying)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.update() }
            .store(in: &cancellables)
    }

    private func update() {
        guard let episode = player.currentEpisode else {
            return
        }
        titleLabel.text = episode.title
        artworkView.load(url: LibraryStore.localArtworkURL(for: episode, in: modelContext))
        let image = UIImage(systemName: player.isPlaying ? "pause.fill" : "play.fill")
        playButton.setImage(image, for: .normal)
        playButton.accessibilityLabel = player.isPlaying ? "Pause" : "Play"
    }

    @objc private func togglePlayback() {
        player.togglePlayPause()
    }

    @objc private func open() {
        openNowPlaying?()
    }
}
