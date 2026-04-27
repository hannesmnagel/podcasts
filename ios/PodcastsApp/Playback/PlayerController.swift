import AVFoundation
import Combine
import Foundation
import MediaPlayer

@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var currentEpisode: EpisodeDTO?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval?
    @Published var speed: Float = 3.0 {
        didSet { applyRate() }
    }

    private let player = AVPlayer()
    private var timeObserver: Any?

    init() {
        configureAudioSession()
        configureRemoteCommands()
        observePlaybackTime()
    }

    func play(_ episode: EpisodeDTO) {
        guard let url = URL(string: episode.audioURL) else { return }
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        currentEpisode = episode
        elapsed = 0
        duration = episode.duration
        player.playImmediately(atRate: speed)
        isPlaying = true
        updateNowPlaying(for: episode)
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            player.playImmediately(atRate: speed)
            isPlaying = true
        }
        updateNowPlayingPlaybackState()
    }

    func seek(by seconds: TimeInterval) {
        let current = player.currentTime().seconds
        let targetSeconds = max(0, current + seconds)
        player.seek(to: CMTime(seconds: targetSeconds, preferredTimescale: 600))
    }

    func seek(to fraction: Double) {
        guard let duration, duration.isFinite, duration > 0 else { return }
        player.seek(to: CMTime(seconds: max(0, min(duration, duration * fraction)), preferredTimescale: 600))
    }

    private func applyRate() {
        guard player.timeControlStatus == .playing else { return }
        player.rate = speed
        updateNowPlayingPlaybackState()
    }

    private func observePlaybackTime() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = max(0, time.seconds)
                if let itemDuration = self.player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
                self.updateNowPlayingPlaybackState()
            }
        }
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
            Task { @MainActor in
                self?.player.playImmediately(atRate: self?.speed ?? 1)
                self?.isPlaying = true
                self?.updateNowPlayingPlaybackState()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.player.pause()
                self?.isPlaying = false
                self?.updateNowPlayingPlaybackState()
            }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.seek(by: 30) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.seek(by: -15) }
            return .success
        }
    }

    private func updateNowPlaying(for episode: EpisodeDTO) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: episode.title,
            MPNowPlayingInfoPropertyPlaybackRate: speed,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed
        ]
    }

    private func updateNowPlayingPlaybackState() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? speed : 0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
