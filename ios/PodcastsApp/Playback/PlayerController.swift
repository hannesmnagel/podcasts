import AVFoundation
import Combine
import Foundation
import MediaPlayer
import UIKit

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
    private var cancellables: Set<AnyCancellable> = []
    private var artworkTask: Task<Void, Never>?
    private var nowPlayingArtworkURL: URL?

    init() {
        debugLog("init")
        configureAudioSession()
        configureRemoteCommands()
        observePlaybackTime()
        observePlaybackState()
    }

    func play(_ episode: EpisodeDTO, at startTime: TimeInterval = 0, artworkURL: URL? = nil) {
        debugLog("play requested id=\(episode.stableID) speed=\(speed) url=\(episode.audioURL)")
        guard let url = URL(string: episode.audioURL) else { return }
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        debugLog("created AVPlayerItem")
        player.replaceCurrentItem(with: item)
        debugLog("replaced current item")
        elapsed = max(0, startTime)
        duration = episode.duration
        if startTime > 0 {
            debugLog("seeking to \(startTime)")
            item.seek(to: CMTime(seconds: startTime, preferredTimescale: 600), completionHandler: nil)
        }
        debugLog("calling playImmediately")
        player.playImmediately(atRate: speed)
        debugLog("playImmediately returned")
        isPlaying = true
        debugLog("isPlaying published")
        updateNowPlaying(for: episode, artworkURL: artworkURL ?? episode.imageURL.flatMap(URL.init))
        debugLog("now playing metadata updated")
        currentEpisode = episode
        debugLog("currentEpisode published")
    }

    func togglePlayPause() {
        debugLog("toggle requested status=\(player.timeControlStatus.rawValue)")
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

    func seek(toTime seconds: TimeInterval) {
        let upperBound = duration ?? seconds
        let targetSeconds = max(0, min(upperBound, seconds))
        player.seek(to: CMTime(seconds: targetSeconds, preferredTimescale: 600))
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
            debugLog("configuring audio session")
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            debugLog("audio session active")
        } catch {
            debugLog("audio session failed: \(error.localizedDescription)")
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player.currentItem != nil else { return }
                self.player.playImmediately(atRate: self.speed)
                self.isPlaying = true
                self.updateNowPlayingPlaybackState()
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
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
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

    private func observePlaybackState() {
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.isPlaying = status == .playing
                self.updateNowPlayingPlaybackState()
            }
            .store(in: &cancellables)
    }

    func updateNowPlayingArtwork(url: URL?) {
        guard ProcessInfo.processInfo.environment["PODCASTS_ENABLE_NOW_PLAYING_ARTWORK"] == "1" else {
            debugLog("skipping now playing artwork url=\(url?.absoluteString ?? "nil")")
            return
        }
        guard url != nowPlayingArtworkURL else { return }
        nowPlayingArtworkURL = url
        artworkTask?.cancel()

        guard let url else {
            if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                info.removeValue(forKey: MPMediaItemPropertyArtwork)
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
            return
        }

        artworkTask = Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, let image = UIImage(data: data) else { return }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            } catch {
                guard !Task.isCancelled else { return }
                if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                    info.removeValue(forKey: MPMediaItemPropertyArtwork)
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            }
        }
    }

    private func updateNowPlaying(for episode: EpisodeDTO, artworkURL: URL?) {
        debugLog("setting now playing info")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: episode.title,
            MPNowPlayingInfoPropertyPlaybackRate: speed,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPMediaItemPropertyPlaybackDuration: duration ?? 0
        ]
        updateNowPlayingArtwork(url: artworkURL)
    }

    private func updateNowPlayingPlaybackState() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? speed : 0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func debugLog(_ message: String) {
        NSLog("[PodcastsDebug][Player] %@", message)
    }
}
