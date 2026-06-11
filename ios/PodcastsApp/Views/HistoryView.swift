import SwiftData
import SwiftUI
import UIKit

final class HistoryViewController: UIViewController {
    private let modelContext: ModelContext
    private let player: PlayerController

    init(modelContext: ModelContext, player: PlayerController) {
        self.modelContext = modelContext
        self.player = player
        super.init(nibName: nil, bundle: nil)
        title = "History"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        #if !targetEnvironment(macCatalyst)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.navigationController?.dismiss(animated: true) }
        )
        #endif
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Clear All", style: .plain, target: self, action: #selector(clearAll))
        navigationItem.rightBarButtonItem?.tintColor = .systemRed

        let host = UIHostingController(rootView: HistorySheet(player: player).modelContext(modelContext))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)
    }

    @objc private func clearAll() {
        let alert = UIAlertController(title: "Clear History", message: "This will delete all recent events. Older summarised data will be kept.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            guard let self else { return }
            try? self.modelContext.delete(model: AppEvent.self)
            try? self.modelContext.save()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - Shared helpers

private struct PlaybackSegment {
    let occurredAt: Date
    let episodeStableID: String
    let episodeTitle: String?
    let podcastStableID: String?
    let startPosition: Double
    let endPosition: Double
    let speed: Double

    var wallEnd: Date { occurredAt.addingTimeInterval((endPosition - startPosition) / speed) }

    func audioPosition(at date: Date) -> Double {
        startPosition + date.timeIntervalSince(occurredAt) * speed
    }

    func episodeStub() -> EpisodeDTO {
        EpisodeDTO(id: nil, podcastStableID: podcastStableID,
                   stableID: episodeStableID, title: episodeTitle ?? "",
                   summary: nil, audioURL: "", imageURL: nil, publishedAt: nil, duration: nil)
    }
}

private let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.doesRelativeDateFormatting = true
    f.dateStyle = .medium
    f.timeStyle = .none
    return f
}()

private func groupByDay<T>(_ items: [T], date keyPath: KeyPath<T, Date>) -> [(String, [T])] {
    let cal = Calendar.current
    var dayOrder: [String: Date] = [:]
    let grouped = Dictionary(grouping: items) { item -> String in
        let d = cal.startOfDay(for: item[keyPath: keyPath])
        let key = dayFormatter.string(from: d)
        if dayOrder[key] == nil { dayOrder[key] = d }
        return key
    }
    return grouped.sorted { dayOrder[$0.key, default: .distantPast] > dayOrder[$1.key, default: .distantPast] }
}

private func formatAudioTime(_ t: Double) -> String {
    let h = Int(t) / 3600
    let m = (Int(t) % 3600) / 60
    let s = Int(t) % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

// MARK: - HistorySheet

private struct HistorySheet: View {
    let player: PlayerController

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppEvent.occurredAt, order: .reverse) private var events: [AppEvent]
    @Query(sort: \PodcastDailySummary.date, order: .reverse) private var summaries: [PodcastDailySummary]

    @State private var showRewindPicker = false

    var body: some View {
        List {
            if !events.isEmpty {
                Section {
                    Button {
                        if player.isPlaying { player.togglePlayPause() }
                        showRewindPicker = true
                    } label: {
                        Label("Rewind to a moment…", systemImage: "clock.arrow.counterclockwise")
                    }
                }
            }
            if events.isEmpty && summaries.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock", description: Text("Actions like playing, downloading, and marking episodes will appear here."))
            } else {
                ForEach(groupByDay(events, date: \.occurredAt), id: \.0) { day, dayEvents in
                    Section(day) {
                        ForEach(dayEvents) { event in
                            EventRow(event: event, player: player, modelContext: modelContext)
                        }
                    }
                }
                if !summaries.isEmpty {
                    ForEach(groupByDay(summaries, date: \.date), id: \.0) { day, daySummaries in
                        Section(day) {
                            ForEach(daySummaries) { summary in
                                SummaryRow(summary: summary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $showRewindPicker) {
            RewindPickerSheet(player: player, events: events, modelContext: modelContext)
        }
    }
}

// MARK: - EventRow

private struct EventRow: View {
    let event: AppEvent
    let player: PlayerController
    let modelContext: ModelContext

    private var isCurrentEpisode: Bool {
        player.currentEpisode?.stableID == event.episodeStableID
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 28)
                VStack(alignment: .leading) {
                    Text(label)
                        .font(.subheadline)
                    if let sub = sublabel {
                        Text(sub)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(event.occurredAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            undoButton
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var undoButton: some View {
        switch event.kind {
        case AppEvent.Kind.playback:
            if isCurrentEpisode, let start = event.startPosition, let end = event.endPosition {
                HStack {
                    SeekButton(label: formatAudioTime(start), systemImage: "arrow.left.to.line") {
                        performSeek(to: start)
                    }
                    SeekButton(label: formatAudioTime(end), systemImage: "arrow.right.to.line") {
                        performSeek(to: end)
                    }
                }
                .padding(.leading, 28)
            }
        case AppEvent.Kind.historySeek:
            if isCurrentEpisode, let from = event.startPosition {
                SeekButton(label: "Back to \(formatAudioTime(from))", systemImage: "arrow.uturn.left") {
                    performSeek(to: from)
                }
                .padding(.leading, 28)
            }
        case AppEvent.Kind.markPlayed:
            if let ep = eventEpisode {
                SeekButton(label: "Mark Unplayed", systemImage: "arrow.uturn.left") {
                    LibraryStore.markUnplayed(ep, in: modelContext)
                }
                .padding(.leading, 28)
            }
        case AppEvent.Kind.markUnplayed:
            if let ep = eventEpisode {
                SeekButton(label: "Mark Played", systemImage: "arrow.uturn.left") {
                    LibraryStore.markPlayed(ep, in: modelContext)
                }
                .padding(.leading, 28)
            }
        case AppEvent.Kind.hide:
            if let ep = eventEpisode {
                SeekButton(label: "Restore Episode", systemImage: "arrow.uturn.left") {
                    LibraryStore.restoreDeleted(ep, in: modelContext)
                }
                .padding(.leading, 28)
            }
        case AppEvent.Kind.restore:
            if let ep = eventEpisode {
                SeekButton(label: "Hide Again", systemImage: "arrow.uturn.left") {
                    LibraryStore.markDeleted(ep, in: modelContext)
                }
                .padding(.leading, 28)
            }
        case AppEvent.Kind.download:
            if let ep = eventEpisode {
                SeekButton(label: "Delete Download", systemImage: "arrow.uturn.left") {
                    LibraryStore.removeDownload(for: ep, in: modelContext)
                }
                .padding(.leading, 28)
            }
        case AppEvent.Kind.deleteDownload:
            if let ep = eventEpisode {
                SeekButton(label: "Re-download", systemImage: "arrow.uturn.left") {
                    Task { await LibraryStore.downloadAudio(for: ep, in: modelContext) }
                }
                .padding(.leading, 28)
            }
        default:
            EmptyView()
        }
    }

    private var eventEpisode: EpisodeDTO? {
        guard let stableID = event.episodeStableID,
              let title = event.episodeTitle else { return nil }
        return EpisodeDTO(id: nil, podcastStableID: event.podcastStableID,
                          stableID: stableID, title: title,
                          summary: nil, audioURL: "", imageURL: nil, publishedAt: nil, duration: nil)
    }

    private func performSeek(to target: Double) {
        guard let episode = player.currentEpisode else { return }
        EventLogger.shared?.logHistorySeek(from: player.elapsed, to: target, episode: episode)
        player.seek(toTime: target)
    }

    private var icon: String {
        switch event.kind {
        case AppEvent.Kind.playback:        return "play.fill"
        case AppEvent.Kind.historySeek:     return "clock.arrow.circlepath"
        case AppEvent.Kind.markPlayed:      return "checkmark.circle.fill"
        case AppEvent.Kind.markUnplayed:    return "circle"
        case AppEvent.Kind.hide:            return "eye.slash.fill"
        case AppEvent.Kind.restore:         return "arrow.uturn.backward"
        case AppEvent.Kind.download:        return "arrow.down.circle.fill"
        case AppEvent.Kind.deleteDownload:  return "trash.fill"
        default:                            return "circle.fill"
        }
    }

    private var color: Color {
        switch event.kind {
        case AppEvent.Kind.playback:        return .orange
        case AppEvent.Kind.historySeek:     return .purple
        case AppEvent.Kind.markPlayed:      return .green
        case AppEvent.Kind.hide:            return .red
        case AppEvent.Kind.deleteDownload:  return .red
        case AppEvent.Kind.download:        return .blue
        default:                            return .secondary
        }
    }

    private var label: String {
        let title = event.episodeTitle ?? "Unknown episode"
        switch event.kind {
        case AppEvent.Kind.playback:        return "Played \(title)"
        case AppEvent.Kind.historySeek:
            guard let from = event.startPosition, let to = event.endPosition else { return "Seeked in \(title)" }
            return "Seeked \(formatAudioTime(from)) → \(formatAudioTime(to)) in \(title)"
        case AppEvent.Kind.markPlayed:      return "Marked played: \(title)"
        case AppEvent.Kind.markUnplayed:    return "Marked unplayed: \(title)"
        case AppEvent.Kind.hide:            return "Hidden: \(title)"
        case AppEvent.Kind.restore:         return "Restored: \(title)"
        case AppEvent.Kind.download:        return "Downloaded: \(title)"
        case AppEvent.Kind.deleteDownload:  return "Deleted download: \(title)"
        default:                            return title
        }
    }

    private var sublabel: String? {
        guard event.kind == AppEvent.Kind.playback,
              let start = event.startPosition,
              let end = event.endPosition else { return nil }
        let range = "\(formatAudioTime(start)) → \(formatAudioTime(end))"
        guard let speed = event.playbackSpeed, speed != 1.0 else { return range }
        let saved = (end - start) / speed - (end - start)
        return "\(range) · \(formatDuration(abs(saved))) saved at \(String(format: "%.1f", speed))×"
    }

    private func formatDuration(_ t: Double) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}

// MARK: - RewindPickerSheet

private struct RewindPickerSheet: View {
    let player: PlayerController
    let events: [AppEvent]
    let modelContext: ModelContext

    @Environment(\.dismiss) private var dismiss
    @State private var fraction: Double = 1.0
    @State private var cachedSegments: [PlaybackSegment] = []
    @State private var downloadConfirmation: (toDelete: [EpisodeDTO], toRedownload: [EpisodeDTO])?

    private var earliest: Date {
        let base = events.last?.occurredAt ?? Date.now.addingTimeInterval(-48 * 3600)
        return base.addingTimeInterval(-5 * 60)
    }

    private var targetDate: Date {
        earliest.addingTimeInterval(fraction * Date.now.timeIntervalSince(earliest))
    }

    private func buildSegments() -> [PlaybackSegment] {
        var segs = events.compactMap { ev -> PlaybackSegment? in
            guard ev.kind == AppEvent.Kind.playback,
                  let sid = ev.episodeStableID,
                  let s = ev.startPosition, let e = ev.endPosition,
                  let sp = ev.playbackSpeed, sp > 0 else { return nil }
            return PlaybackSegment(occurredAt: ev.occurredAt, episodeStableID: sid,
                                   episodeTitle: ev.episodeTitle, podcastStableID: ev.podcastStableID,
                                   startPosition: s, endPosition: e, speed: sp)
        }
        if let logger = EventLogger.shared,
           let ep = logger.sessionEpisode,
           let startedAt = logger.sessionStartedAt,
           let startPos = logger.sessionStartPosition,
           let speed = logger.sessionSpeed {
            segs.insert(PlaybackSegment(occurredAt: startedAt, episodeStableID: ep.stableID,
                                        episodeTitle: ep.title, podcastStableID: ep.podcastStableID,
                                        startPosition: startPos, endPosition: player.elapsed, speed: Double(speed)), at: 0)
        }
        return segs
    }

    private var activeSegment: PlaybackSegment? {
        cachedSegments.first { $0.occurredAt <= targetDate && $0.wallEnd >= targetDate }
    }

    private var nextSegment: PlaybackSegment? {
        cachedSegments.filter { $0.occurredAt > targetDate }.min(by: { $0.occurredAt < $1.occurredAt })
    }

    var body: some View {
        NavigationStack {
            VStack {
                HStack {
                    Text(earliest, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("Now")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal)

                Slider(value: $fraction, in: 0...1)
                    .tint(.orange)
                    .padding(.horizontal)

                Text(targetDate.formatted(date: .abbreviated, time: .standard))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .padding(.top, 4)

                previewCard
                    .padding(.horizontal)
                    .padding(.top, 8)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Rewind to moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rewind") { performRewind() }
                }
            }
            .onAppear { cachedSegments = buildSegments() }
            .alert("Keep downloaded episodes?", isPresented: .init(
                get: { downloadConfirmation != nil },
                set: { if !$0 { downloadConfirmation = nil } }
            )) {
                Button("Keep", role: .cancel) {
                    downloadConfirmation = nil
                    dismiss()
                }
                Button("Delete Downloads", role: .destructive) {
                    if let conf = downloadConfirmation {
                        conf.toDelete.forEach { LibraryStore.removeDownload(for: $0, in: modelContext) }
                    }
                    downloadConfirmation = nil
                    dismiss()
                }
            } message: {
                Text("Some episodes were downloaded during the rewound period. Do you want to delete those downloads?")
            }
        }
    }

    @ViewBuilder
    private var previewCard: some View {
        VStack(alignment: .leading) {
            if let seg = activeSegment {
                Label("Playing at this moment", systemImage: "play.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(seg.episodeTitle ?? "Unknown episode")
                    .font(.subheadline)
                Text("Resume at \(formatAudioTime(seg.audioPosition(at: targetDate)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let seg = nextSegment {
                Label("Nothing playing — will resume at next session", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(seg.episodeTitle ?? "Unknown episode")
                    .font(.subheadline)
                Text("Starts at \(formatAudioTime(seg.startPosition))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Nothing playing at this moment", systemImage: "minus.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("State will be rewound, player unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("All changes since this moment will be undone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func performRewind() {
        let result = EventLogger.shared?.rewindState(to: targetDate)

        let seg = activeSegment ?? nextSegment
        let audioPos = activeSegment.map { $0.audioPosition(at: targetDate) } ?? seg?.startPosition

        if let seg, let audioPos {
            let stub = seg.episodeStub()
            let episode = LibraryStore.episodeState(for: stub, in: modelContext)?.episodeDTO(preferDownloadedFile: true) ?? stub
            EventLogger.shared?.logHistorySeek(from: player.elapsed, to: audioPos, episode: episode)
            if player.currentEpisode?.stableID == seg.episodeStableID {
                player.seek(toTime: audioPos)
            } else {
                player.play(episode, at: audioPos)
            }
        }

        if let result, (!result.toDelete.isEmpty || !result.toRedownload.isEmpty) {
            downloadConfirmation = result
        } else {
            dismiss()
        }
    }
}

// MARK: - SeekButton

private struct SeekButton: View {
    let label: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SummaryRow

private struct SummaryRow: View {
    let summary: PodcastDailySummary

    var body: some View {
        VStack(alignment: .leading) {
            Text(summary.podcastTitle.isEmpty ? "Unknown Podcast" : summary.podcastTitle)
                .font(.subheadline)
            HStack {
                Label(formatDuration(summary.listenedSeconds), systemImage: "clock")
                Text("·")
                Label(formatDuration(summary.playedSeconds), systemImage: "headphones")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func formatDuration(_ t: Double) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
