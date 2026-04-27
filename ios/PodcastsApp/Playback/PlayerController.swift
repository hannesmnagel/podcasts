import AVFoundation
import Combine
import Foundation
import MediaPlayer

@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var currentEpisode: EpisodeDTO?
    @Published var speed: Float = 3.0 {
        didSet { applyRate() }
    }

    private let player = AVPlayer()

    init() {
        configureAudioSession()
        configureRemoteCommands()
    }

    func play(_ episode: EpisodeDTO) {
        guard let url = URL(string: episode.audioURL) else { return }
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        currentEpisode = episode
        player.playImmediately(atRate: speed)
        updateNowPlaying(for: episode)
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.playImmediately(atRate: speed)
        }
    }

    private func applyRate() {
        guard player.timeControlStatus == .playing else { return }
        player.rate = speed
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            assertionFailure("Audio session failed: \(error)")
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player.playImmediately(atRate: self?.speed ?? 1) }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player.pause() }
            return .success
        }
    }

    private func updateNowPlaying(for episode: EpisodeDTO) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: episode.title,
            MPNowPlayingInfoPropertyPlaybackRate: speed
        ]
    }
}
