import AVFoundation
import Combine
import Foundation
import ImageIO
import MediaPlayer
import UIKit

@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var currentEpisode: EpisodeDTO?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval?
    @Published var speed: Float = 3.0 {
        didSet {
            let clamped = Float(PlaybackSettings.clampedSpeed(Double(speed)))
            if speed != clamped {
                speed = clamped
                return
            }
            applyRate()
        }
    }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var itemCancellables: Set<AnyCancellable> = []
    private var artworkTask: Task<Void, Never>?
    private var nowPlayingArtworkURL: URL?

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        configureAudioSession()
        configureRemoteCommands()
        observePlaybackTime()
        observePlaybackState()
    }

    func play(_ episode: EpisodeDTO, at startTime: TimeInterval = 0, artworkURL: URL? = nil) {
        load(episode, at: startTime, artworkURL: artworkURL, shouldPlay: true)
    }

    func restore(_ episode: EpisodeDTO, at startTime: TimeInterval, artworkURL: URL? = nil) {
        load(episode, at: startTime, artworkURL: artworkURL, shouldPlay: false)
    }

    private func load(_ episode: EpisodeDTO, at startTime: TimeInterval, artworkURL: URL?, shouldPlay: Bool) {
        guard let url = playableURL(for: episode) else {
            debug("play failed invalid audio url=\(episode.audioURL)")
            isPlaying = false
            return
        }
        debug("play requested id=\(episode.stableID) speed=\(effectiveSpeed) url=\(url.absoluteString)")
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        observeItem(item, episode: episode, startTime: startTime)
        player.replaceCurrentItem(with: item)
        elapsed = max(0, startTime)
        duration = episode.duration
        currentEpisode = episode
        isPlaying = shouldPlay
        if startTime > 0 {
            item.seek(to: CMTime(seconds: startTime, preferredTimescale: 600), completionHandler: nil)
        }
        if shouldPlay {
            player.playImmediately(atRate: effectiveSpeed)
        } else {
            player.pause()
            isPlaying = false
        }
        updateNowPlaying(for: episode, artworkURL: artworkURL ?? episode.imageURL.flatMap(URL.init))
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            player.playImmediately(atRate: effectiveSpeed)
            isPlaying = true
        }
        updateNowPlayingPlaybackState()
    }

    func seek(by seconds: TimeInterval) {
        let current = player.currentTime().seconds
        let targetSeconds = max(0, current + seconds)
        elapsed = targetSeconds
        player.seek(to: CMTime(seconds: targetSeconds, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlayingPlaybackState() }
        }
    }

    func seek(to fraction: Double) {
        guard let duration, duration.isFinite, duration > 0 else { return }
        let targetSeconds = max(0, min(duration, duration * fraction))
        elapsed = targetSeconds
        player.seek(to: CMTime(seconds: targetSeconds, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlayingPlaybackState() }
        }
    }

    func seek(toTime seconds: TimeInterval) {
        let upperBound = duration ?? seconds
        let targetSeconds = max(0, min(upperBound, seconds))
        elapsed = targetSeconds
        player.seek(to: CMTime(seconds: targetSeconds, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlayingPlaybackState() }
        }
    }

    private func applyRate() {
        guard player.timeControlStatus == .playing else { return }
        player.rate = effectiveSpeed
        updateNowPlayingPlaybackState()
    }

    private var effectiveSpeed: Float {
        Float(PlaybackSettings.clampedSpeed(Double(speed)))
    }

    private func observePlaybackTime() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = max(0, time.seconds)
                if let itemDuration = self.player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
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

    private func playableURL(for episode: EpisodeDTO) -> URL? {
        guard let url = URL(string: episode.audioURL) else { return nil }
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
            return nil
        }
        return url
    }

    private func observeItem(_ item: AVPlayerItem, episode: EpisodeDTO, startTime: TimeInterval) {
        itemCancellables.removeAll()
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self, let item, self.player.currentItem === item else { return }
                switch status {
                case .readyToPlay:
                    self.debug("item ready id=\(episode.stableID) duration=\(item.duration.seconds)")
                    if startTime > 0, self.elapsed < startTime {
                        item.seek(to: CMTime(seconds: startTime, preferredTimescale: 600), completionHandler: nil)
                    }
                    if self.isPlaying, self.player.timeControlStatus != .playing {
                        self.player.playImmediately(atRate: self.effectiveSpeed)
                    }
                case .failed:
                    self.debug("item failed id=\(episode.stableID) error=\(item.error?.localizedDescription ?? "unknown")")
                    self.isPlaying = false
                    self.updateNowPlayingPlaybackState()
                case .unknown:
                    self.debug("item status unknown id=\(episode.stableID)")
                @unknown default:
                    self.debug("item status unhandled id=\(episode.stableID)")
                }
            }
            .store(in: &itemCancellables)

        item.publisher(for: \.isPlaybackLikelyToKeepUp)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] likely in
                guard let self, let item, self.player.currentItem === item else { return }
                self.debug("item likelyToKeepUp=\(likely) id=\(episode.stableID)")
            }
            .store(in: &itemCancellables)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player.currentItem != nil else { return }
                self.player.playImmediately(atRate: self.effectiveSpeed)
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
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: SeekSettings.forwardSeconds)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.seek(by: SeekSettings.forwardSeconds) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: SeekSettings.backSeconds)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.seek(by: -SeekSettings.backSeconds) }
            return .success
        }
    }

    private func observePlaybackState() {
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.isPlaying = status == .playing
                self.debug("timeControlStatus=\(status.rawValue) rate=\(self.player.rate) reason=\(self.player.reasonForWaitingToPlay?.rawValue ?? "none") error=\(self.player.error?.localizedDescription ?? "none")")
                self.updateNowPlayingPlaybackState()
            }
            .store(in: &cancellables)
    }

    func updateNowPlayingArtwork(url: URL?) {
        guard url != nowPlayingArtworkURL else { return }
        nowPlayingArtworkURL = url
        artworkTask?.cancel()

        guard let url else {
            clearNowPlayingArtwork()
            return
        }

        artworkTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                debug(url.isFileURL ? "using local now playing artwork url=\(url.path)" : "caching remote now playing artwork url=\(url.absoluteString)")
                guard let cgImage = try await Self.preparedNowPlayingArtwork(from: url) else {
                    clearNowPlayingArtwork()
                    return
                }
                guard !Task.isCancelled else { return }
                let image = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(image: image)
                setNowPlayingInfo(info, reason: "artwork")
            } catch {
                guard !Task.isCancelled else { return }
                debug("failed now playing artwork error=\(error)")
                clearNowPlayingArtwork()
            }
        }
    }

    @concurrent
    private static func preparedNowPlayingArtwork(from url: URL) async throws -> CGImage? {
        let localURL = url.isFileURL ? url : try await LocalMediaCache.cachedOrDownload(url)
        let data = try Data(contentsOf: localURL)
        return decodedNowPlayingArtwork(from: data)
    }

    private func clearNowPlayingArtwork() {
        if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
            setNowPlayingInfo(info, reason: "clear artwork")
        }
    }

    nonisolated private static func decodedNowPlayingArtwork(from data: Data) -> CGImage? {
        let maxPixelSize: CGFloat = 1024
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        return renderedSquareArtwork(from: cgImage, side: maxPixelSize)
    }

    nonisolated private static func renderedSquareArtwork(from sourceImage: CGImage, side: CGFloat) -> CGImage? {
        let width = sourceImage.width
        let height = sourceImage.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(side),
            height: Int(side),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        let sourceAspect = CGFloat(width) / CGFloat(height)
        let targetRect: CGRect
        if sourceAspect > 1 {
            let targetHeight = side / sourceAspect
            targetRect = CGRect(x: 0, y: (side - targetHeight) / 2, width: side, height: targetHeight)
        } else {
            let targetWidth = side * sourceAspect
            targetRect = CGRect(x: (side - targetWidth) / 2, y: 0, width: targetWidth, height: side)
        }

        context.draw(sourceImage, in: targetRect)
        return context.makeImage()
    }

    private func updateNowPlaying(for episode: EpisodeDTO, artworkURL: URL?) {
        setNowPlayingInfo([
            MPMediaItemPropertyTitle: episode.title,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? effectiveSpeed : 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPMediaItemPropertyPlaybackDuration: duration ?? 0
        ], reason: "episode metadata")
        updateNowPlayingArtwork(url: artworkURL)
    }

    private func updateNowPlayingPlaybackState() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? effectiveSpeed : 0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        setNowPlayingInfo(info, reason: "playback state")
    }

    private func setNowPlayingInfo(_ info: [String: Any], reason: String) {
        debug("setting now playing info reason=\(reason) keys=\(info.keys.sorted())")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        debug("set now playing info complete reason=\(reason)")
    }

    private func debug(_ message: String) {
        #if DEBUG
        print("[PodcastsDebug][NowPlayingInfo] \(message)")
        #endif
    }
}
