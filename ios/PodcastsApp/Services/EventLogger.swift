import Combine
import Foundation
import SwiftData

@MainActor
final class EventLogger {
    static let collapseThreshold: TimeInterval = 2 * 24 * 60 * 60  // 2 days
    static var shared: EventLogger?

    private let context: ModelContext
    private var cancellables = Set<AnyCancellable>()
    private var pendingSaveTask: Task<Void, Never>?
    private var podcastTitleCache: [String: String] = [:]

    private(set) var sessionEpisode: EpisodeDTO?
    private(set) var sessionStartedAt: Date?
    private(set) var sessionStartPosition: Double?
    private(set) var sessionSpeed: Double?
    private var sessionPodcastTitle: String?  // looked up at open, not close

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Player observation

    func observe(_ player: PlayerController) {
        player.$isPlaying
            .removeDuplicates()
            .sink { [weak self, weak player] isPlaying in
                guard let self, let player else { return }
                if isPlaying {
                    self.openSession(episode: player.currentEpisode, position: player.elapsed, speed: Double(player.speed))
                } else {
                    self.closeSession(endPosition: player.elapsed)
                }
            }
            .store(in: &cancellables)

        player.$currentEpisode
            .removeDuplicates(by: { $0?.stableID == $1?.stableID })
            .dropFirst()
            .sink { [weak self, weak player] newEpisode in
                guard let self, let player else { return }
                self.closeSession(endPosition: player.elapsed)
                if player.isPlaying, let newEpisode {
                    self.openSession(episode: newEpisode, position: player.elapsed, speed: Double(player.speed))
                }
            }
            .store(in: &cancellables)

        player.$speed
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self, weak player] newSpeed in
                guard let self, let player, player.isPlaying else { return }
                self.closeSession(endPosition: player.elapsed)
                self.openSession(episode: player.currentEpisode, position: player.elapsed, speed: Double(newSpeed))
            }
            .store(in: &cancellables)

        // Debounced — progress bar scrubbing fires didSeek on every frame; only split on the final resting position
        player.$didSeek
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self, weak player] seekDestination in
                guard let self, let player, player.isPlaying else { return }
                self.closeSession(endPosition: seekDestination)
                self.openSession(episode: player.currentEpisode, position: seekDestination, speed: Double(player.speed))
            }
            .store(in: &cancellables)
    }

    private func openSession(episode: EpisodeDTO?, position: Double, speed: Double) {
        guard let episode else { return }
        sessionEpisode = episode
        sessionStartedAt = .now
        sessionStartPosition = position
        sessionSpeed = speed
        // Look up title at open time so closeSession has no DB work to do
        sessionPodcastTitle = podcastTitle(for: episode.podcastStableID)
    }

    func closeSession(endPosition: Double) {
        guard let episode = sessionEpisode,
              let startedAt = sessionStartedAt,
              let startPos = sessionStartPosition,
              let speed = sessionSpeed else { return }
        defer {
            sessionEpisode = nil
            sessionStartedAt = nil
            sessionStartPosition = nil
            sessionSpeed = nil
            sessionPodcastTitle = nil
        }
        let audioSeconds = endPosition - startPos
        guard audioSeconds > 10 else { return }
        let event = AppEvent(
            kind: AppEvent.Kind.playback,
            episodeStableID: episode.stableID,
            episodeTitle: episode.title,
            podcastStableID: episode.podcastStableID,
            podcastTitle: sessionPodcastTitle,
            startPosition: startPos,
            endPosition: endPosition,
            playbackSpeed: speed
        )
        event.occurredAt = startedAt
        context.insert(event)
        scheduleSave()
    }

    // MARK: - Discrete events

    func log(kind: String, episode: EpisodeDTO?, podcastStableID: String? = nil, podcastTitle: String? = nil) {
        let event = AppEvent(
            kind: kind,
            episodeStableID: episode?.stableID,
            episodeTitle: episode?.title,
            podcastStableID: podcastStableID ?? episode?.podcastStableID,
            podcastTitle: podcastTitle
        )
        context.insert(event)
        scheduleSave()
    }

    func logHistorySeek(from: Double, to: Double, episode: EpisodeDTO) {
        let event = AppEvent(
            kind: AppEvent.Kind.historySeek,
            episodeStableID: episode.stableID,
            episodeTitle: episode.title,
            podcastStableID: episode.podcastStableID,
            podcastTitle: podcastTitle(for: episode.podcastStableID),
            startPosition: from,
            endPosition: to
        )
        context.insert(event)
        scheduleSave()
    }

    // MARK: - Rewind

    /// Undoes all discrete state-changing events after `date` in reverse order.
    /// Download/deleteDownload events are skipped — handle them separately with confirmation.
    /// Returns episodes whose download state would change if the caller wants to handle them.
    @discardableResult
    func rewindState(to date: Date) -> (toDelete: [EpisodeDTO], toRedownload: [EpisodeDTO]) {
        let descriptor = FetchDescriptor<AppEvent>(
            predicate: #Predicate { $0.occurredAt > date },
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        let events = (try? context.fetch(descriptor)) ?? []
        var toDelete: [EpisodeDTO] = []
        var toRedownload: [EpisodeDTO] = []

        for event in events {
            guard let stableID = event.episodeStableID,
                  let title = event.episodeTitle else { continue }
            let ep = EpisodeDTO(
                id: nil, podcastStableID: event.podcastStableID,
                stableID: stableID, title: title,
                summary: nil, audioURL: "", imageURL: nil, publishedAt: nil, duration: nil
            )
            switch event.kind {
            case AppEvent.Kind.markPlayed:      LibraryStore.markUnplayed(ep, in: context)
            case AppEvent.Kind.markUnplayed:    LibraryStore.markPlayed(ep, in: context)
            case AppEvent.Kind.hide:            LibraryStore.restoreDeleted(ep, in: context)
            case AppEvent.Kind.restore:         LibraryStore.markDeleted(ep, in: context)
            case AppEvent.Kind.download:        toDelete.append(ep)
            case AppEvent.Kind.deleteDownload:  toRedownload.append(ep)
            default: break
            }
        }
        return (toDelete, toRedownload)
    }

    // MARK: - Collapse old events

    func collapseOldEventsIfNeeded() {
        let cutoff = Date.now.addingTimeInterval(-Self.collapseThreshold)
        let oldDescriptor = FetchDescriptor<AppEvent>(
            predicate: #Predicate { $0.occurredAt < cutoff }
        )
        guard let old = try? context.fetch(oldDescriptor), !old.isEmpty else { return }

        var summaryMap: [String: PodcastDailySummary] = [:]
        for s in (try? context.fetch(FetchDescriptor<PodcastDailySummary>())) ?? [] {
            summaryMap[summaryKey(podcastID: s.podcastStableID, date: s.date)] = s
        }

        let cal = Calendar.current
        for event in old where event.kind == AppEvent.Kind.playback {
            guard let podcastID = event.podcastStableID,
                  let startPos = event.startPosition,
                  let endPos = event.endPosition,
                  let speed = event.playbackSpeed,
                  endPos > startPos else { continue }

            let day = cal.startOfDay(for: event.occurredAt)
            let key = summaryKey(podcastID: podcastID, date: day)
            let summary = summaryMap[key] ?? {
                let s = PodcastDailySummary(date: day, podcastStableID: podcastID, podcastTitle: event.podcastTitle ?? "")
                context.insert(s)
                summaryMap[key] = s
                return s
            }()
            let audioSeconds = endPos - startPos
            summary.playedSeconds += audioSeconds
            summary.listenedSeconds += audioSeconds / max(0.1, speed)
        }

        old.forEach { context.delete($0) }
        try? context.save()
    }

    // MARK: - Sleep recovery

    func lastRecordedPosition(for episodeID: String, currentPosition: Double) -> Double? {
        let descriptor = FetchDescriptor<AppEvent>(
            predicate: #Predicate { $0.episodeStableID == episodeID && $0.kind == "playback" },
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        guard let event = (try? context.fetch(descriptor))?.first,
              let endPos = event.endPosition,
              endPos - currentPosition > 30 else { return nil }
        return endPos
    }

    // MARK: - Helpers

    private func podcastTitle(for podcastStableID: String?) -> String? {
        guard let id = podcastStableID else { return nil }
        if let cached = podcastTitleCache[id] { return cached }
        let descriptor = FetchDescriptor<PodcastSubscription>(predicate: #Predicate { $0.stableID == id })
        let title = (try? context.fetch(descriptor))?.first?.title
        if let title { podcastTitleCache[id] = title }
        return title
    }

    private func summaryKey(podcastID: String, date: Date) -> String {
        "\(podcastID)|\(date.timeIntervalSinceReferenceDate)"
    }

    // Debounced save — batches rapid successive inserts into one write
    private func scheduleSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            try? self?.context.save()
        }
    }
}
