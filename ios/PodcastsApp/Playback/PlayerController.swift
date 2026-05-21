import AVFoundation
import Combine
import Foundation
import ImageIO
import MediaPlayer
import UIKit

struct SeekUndoAction: Equatable, Identifiable {
    let id = UUID()
    let from: TimeInterval
    let to: TimeInterval
}

@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var currentEpisode: EpisodeDTO?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval?
    @Published private(set) var undoSeekAction: SeekUndoAction?
    @Published var speed: Float = Float(PlaybackSettings.globalSpeed) {
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
    private var defaultArtworkURL: URL?
    private var autoSkipChapters: [EpisodeChapterDTO] = []
    private var lastAutoSkippedChapterID: String?
    private var isAutoSkipping = false
    private var didInstallRemoteCommandHandlers = false
    private var shouldResumeAfterAudioInterruption = false

    var playbackDidFinish: ((EpisodeDTO) -> Void)?

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        configureAudioSession()
        configureRemoteCommands()
        observePlaybackTime()
        observePlaybackState()
        observeAudioSessionInterruptions()
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
        item.audioTimePitchAlgorithm = pitchAlgorithm(for: effectiveSpeed)
        observeItem(item, episode: episode, startTime: startTime)
        player.replaceCurrentItem(with: item)
        elapsed = max(0, startTime)
        duration = episode.duration
        currentEpisode = episode
        autoSkipChapters = []
        lastAutoSkippedChapterID = nil
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
        let displayArtworkURL = artworkURL ?? episode.imageURL.flatMap(URL.init)
        defaultArtworkURL = displayArtworkURL
        ArtworkImageView.preload(url: displayArtworkURL)
        updateNowPlaying(for: episode, artworkURL: currentChapterArtworkURL() ?? displayArtworkURL)
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
        let current = currentPlaybackSeconds
        performSeek(to: current + seconds, from: current, resetAutoSkip: true, recordsUndo: true)
    }

    func seek(to fraction: Double) {
        seek(to: fraction, from: nil)
    }

    func seek(to fraction: Double, from sourceSeconds: TimeInterval?) {
        guard let duration, duration.isFinite, duration > 0 else { return }
        performSeek(to: duration * fraction, from: sourceSeconds, resetAutoSkip: true, recordsUndo: true)
    }

    func seek(toTime seconds: TimeInterval) {
        seek(toTime: seconds, resetAutoSkip: true)
    }

    func undoSeek(_ action: SeekUndoAction) {
        guard undoSeekAction?.id == action.id else { return }
        undoSeekAction = nil
        performSeek(to: action.from, resetAutoSkip: true, recordsUndo: false)
    }

    func dismissUndoSeek(_ action: SeekUndoAction) {
        guard undoSeekAction?.id == action.id else { return }
        undoSeekAction = nil
    }

    func updateAutoSkipChapters(_ chapters: [EpisodeChapterDTO]) {
        autoSkipChapters = chapters.sorted { $0.start < $1.start }
        lastAutoSkippedChapterID = nil
        updateCurrentArtworkForPlaybackPosition()
    }

    func refreshSystemPlaybackIntegration() {
        configureAudioSession()
        configureRemoteCommands()
        updateNowPlayingPlaybackState()
    }

    private func seek(toTime seconds: TimeInterval, resetAutoSkip: Bool) {
        performSeek(to: seconds, resetAutoSkip: resetAutoSkip, recordsUndo: resetAutoSkip)
    }

    private var currentPlaybackSeconds: TimeInterval {
        let current = player.currentTime().seconds
        if current.isFinite {
            return max(0, current)
        }
        return max(0, elapsed)
    }

    private func clampedPlaybackTime(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return max(0, elapsed) }
        let lowerBounded = max(0, seconds)
        guard let duration, duration.isFinite, duration > 0 else { return lowerBounded }
        return min(duration, lowerBounded)
    }

    private func performSeek(to seconds: TimeInterval, from sourceSeconds: TimeInterval? = nil, resetAutoSkip: Bool, recordsUndo: Bool) {
        let source = clampedPlaybackTime(sourceSeconds ?? currentPlaybackSeconds)
        let targetSeconds = clampedPlaybackTime(seconds)
        if resetAutoSkip {
            lastAutoSkippedChapterID = nil
        }
        if recordsUndo, currentEpisode != nil, abs(targetSeconds - source) >= 0.5 {
            undoSeekAction = SeekUndoAction(from: source, to: targetSeconds)
        }
        elapsed = targetSeconds
        updateCurrentArtworkForPlaybackPosition()
        player.seek(to: CMTime(seconds: targetSeconds, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in
                self?.updateCurrentArtworkForPlaybackPosition()
                self?.updateNowPlayingPlaybackState()
            }
        }
    }

    private func updateCurrentArtworkForPlaybackPosition() {
        updateNowPlayingArtwork(url: currentChapterArtworkURL() ?? defaultArtworkURL)
    }

    private func currentChapterArtworkURL() -> URL? {
        autoSkipChapters
            .last { $0.start <= elapsed }
            .flatMap(\.displayImageURL)
    }

    private func applyRate() {
        player.currentItem?.audioTimePitchAlgorithm = pitchAlgorithm(for: effectiveSpeed)
        guard player.timeControlStatus == .playing else { return }
        player.rate = effectiveSpeed
        updateNowPlayingPlaybackState()
    }

    private var effectiveSpeed: Float {
        Float(PlaybackSettings.clampedSpeed(Double(speed)))
    }

    private func pitchAlgorithm(for speed: Float) -> AVAudioTimePitchAlgorithm {
        // Spectral pitch preservation gets metallic on some podcast files at very high speeds.
        // Time-domain is less artifact-prone for fast spoken-word playback.
        speed > 2.2 ? .timeDomain : .spectral
    }

    private func observePlaybackTime() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = max(0, time.seconds)
                if let itemDuration = self.player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
                self.autoSkipCurrentChapterIfNeeded()
                self.updateCurrentArtworkForPlaybackPosition()
            }
        }
    }

    private func autoSkipCurrentChapterIfNeeded() {
        guard !isAutoSkipping,
              player.timeControlStatus == .playing,
              autoSkipChapters.count > 1,
              let currentIndex = autoSkipChapters.lastIndex(where: { $0.start <= elapsed }),
              autoSkipChapters.indices.contains(currentIndex) else {
            return
        }
        let chapter = autoSkipChapters[currentIndex]
        let nextStart = autoSkipChapters.indices.contains(currentIndex + 1) ? autoSkipChapters[currentIndex + 1].start : (duration ?? chapter.start)
        guard elapsed >= chapter.start,
              elapsed < max(chapter.start, nextStart - 0.75),
              ChapterSkipRuleStore.shouldSkip(chapterTitle: chapter.title),
              lastAutoSkippedChapterID != chapter.id else {
            return
        }
        lastAutoSkippedChapterID = chapter.id
        isAutoSkipping = true
        let target = max(chapter.start, nextStart + 0.05)
        seek(toTime: target, resetAutoSkip: false)
        if player.timeControlStatus == .playing {
            player.playImmediately(atRate: effectiveSpeed)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            isAutoSkipping = false
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
        guard let url = URL(string: episode.audioURL), url.isFileURL else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
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

        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] _ in
                guard let self, let item, self.player.currentItem === item else { return }
                self.elapsed = self.duration ?? item.duration.seconds
                self.isPlaying = false
                self.updateNowPlayingPlaybackState()
                self.playbackDidFinish?(episode)
            }
            .store(in: &itemCancellables)
    }

    private func configureRemoteCommands() {
        UIApplication.shared.beginReceivingRemoteControlEvents()

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true

        guard !didInstallRemoteCommandHandlers else { return }
        didInstallRemoteCommandHandlers = true

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

    private func observeAudioSessionInterruptions() {
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleAudioSessionInterruption(notification)
            }
            .store(in: &cancellables)
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            shouldResumeAfterAudioInterruption = isPlaying || player.timeControlStatus == .playing
            isPlaying = false
            updateNowPlayingPlaybackState()
            debug("audio interruption began shouldResume=\(shouldResumeAfterAudioInterruption)")
        case .ended:
            configureAudioSession()
            configureRemoteCommands()
            let optionValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionValue)
            let shouldResume = shouldResumeAfterAudioInterruption && options.contains(.shouldResume)
            shouldResumeAfterAudioInterruption = false
            debug("audio interruption ended shouldResume=\(shouldResume) options=\(optionValue)")
            guard shouldResume, player.currentItem != nil else {
                updateNowPlayingPlaybackState()
                return
            }
            player.playImmediately(atRate: effectiveSpeed)
            isPlaying = true
            updateNowPlayingPlaybackState()
        @unknown default:
            updateNowPlayingPlaybackState()
        }
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
        if url.scheme == "data" {
            return dataURLImageData(url).flatMap(decodedNowPlayingArtwork)
        }
        let localURL = url.isFileURL ? url : try await LocalMediaCache.cachedOrDownload(url)
        let data = try Data(contentsOf: localURL)
        return decodedNowPlayingArtwork(from: data)
    }

    nonisolated private static func dataURLImageData(_ url: URL) -> Data? {
        let raw = url.absoluteString
        guard raw.hasPrefix("data:"),
              let comma = raw.firstIndex(of: ",") else {
            return nil
        }
        let metadata = raw[..<comma].lowercased()
        let payload = raw[raw.index(after: comma)...]
        if metadata.contains(";base64") {
            return Data(base64Encoded: String(payload))
        }
        return String(payload).removingPercentEncoding.flatMap { Data($0.utf8) }
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
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = episode.title
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = effectiveSpeed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? effectiveSpeed : 0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPMediaItemPropertyPlaybackDuration] = duration ?? 0
        setNowPlayingInfo(info, reason: "episode metadata")
        updateNowPlayingArtwork(url: artworkURL)
    }

    private func updateNowPlayingPlaybackState() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = effectiveSpeed
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
