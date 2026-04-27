import AVKit
import SwiftUI

struct NowPlayingView: View {
    let showEpisodeDetails: (EpisodeDTO) -> Void
    let showPodcast: (EpisodeDTO) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var player: PlayerController
    @State private var page: NowPlayingPage = .artwork
    @State private var dragOffset: CGFloat = 0
    @State private var transcriptText: String?
    @State private var chapters: [EpisodeChapterDTO] = []
    @State private var isShowingSpeedSheet = false
    private let client = BackendClient()

    var body: some View {
        ZStack {
            Color(white: 0.1).ignoresSafeArea()

            VStack {
                dragHandle

                if let episode = player.currentEpisode {
                    header(episode)
                        .padding(.horizontal)
                    topPager(episode)
                        .frame(maxHeight: 430)
                    NowPlayingProgressView()
                        .padding(.horizontal)
                    playbackControls
                        .padding(.horizontal)
                    Spacer(minLength: 0)
                    bottomBar
                        .padding(.horizontal)
                        .padding(.bottom)
                }
            }
        }
        .preferredColorScheme(.dark)
        .offset(y: dragOffset)
        .animation(.snappy(duration: 0.2), value: dragOffset)
        .simultaneousGesture(dismissGesture)
        .task(id: player.currentEpisode?.stableID) {
            await loadArtifacts()
            page = .artwork
        }
        .sheet(isPresented: $isShowingSpeedSheet) {
            SpeedPickerSheet()
                .environmentObject(player)
                .presentationDetents([.fraction(0.35), .medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var dragHandle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.5))
            .frame(width: 36, height: 5)
            .padding(.top, 10)
    }

    private func header(_ episode: EpisodeDTO) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let publishedAt = episode.publishedAt {
                    Text(publishedAt, style: .date)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            nowPlayingMenu(episode)
        }
        .padding(.top)
    }

    private func topPager(_ episode: EpisodeDTO) -> some View {
        TabView(selection: $page) {
            NowPlayingTranscriptPage(transcriptText: transcriptText)
                .tag(NowPlayingPage.transcript)
            artwork(episode)
                .padding(.horizontal)
                .tag(NowPlayingPage.artwork)
            NowPlayingEpisodeDetailsPage(episode: episode, chapters: chapters)
                .tag(NowPlayingPage.details)
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
    }

    private func artwork(_ episode: EpisodeDTO) -> some View {
        AsyncImage(url: currentArtworkURL(for: episode)) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.25)
                    Image(systemName: "waveform")
                        .font(.system(size: 80))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        .padding(.vertical)
    }

    private var playbackControls: some View {
        HStack {
            Spacer()
            Button { player.seek(by: -15) } label: {
                Image(systemName: "gobackward.15")
                    .font(.title)
                    .frame(width: 64, height: 56)
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40))
                    .frame(width: 76, height: 76)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            Button { player.seek(by: 30) } label: {
                Image(systemName: "goforward.30")
                    .font(.title)
                    .frame(width: 64, height: 56)
            }
            Spacer()
        }
        .tint(.orange)
        .padding(.vertical)
    }

    private var bottomBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.title2)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            Button { isShowingSpeedSheet = true } label: {
                Text(String(format: "%.2g×", player.speed))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 52, minHeight: 44)
                    .padding(.horizontal, 12)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            AVRoutePickerViewRepresented()
                .frame(width: 44, height: 44)
            Spacer()
            if let episode = player.currentEpisode {
                nowPlayingMenu(episode)
            }
        }
        .foregroundStyle(.primary)
    }

    private func nowPlayingMenu(_ episode: EpisodeDTO) -> some View {
        Menu {
            Button("View Episode Details", systemImage: "info.circle") {
                showEpisodeDetails(episode)
            }
            Button(isPlayed(episode) ? "Mark as Unplayed" : "Mark as Played", systemImage: isPlayed(episode) ? "circle" : "checkmark.circle") {
                togglePlayed(episode)
            }
            ShareLink(item: applePodcastsFallbackURL) {
                Label("Share Apple Podcasts Link", systemImage: "square.and.arrow.up")
            }
            .disabled(true)
            Button("Delete Episode", systemImage: "trash", role: .destructive) {}
                .disabled(true)
            Divider()
            Button("Go to Podcast", systemImage: "rectangle.stack") {
                showPodcast(episode)
            }
            .disabled(episode.podcastStableID == nil)
        } label: {
            Image(systemName: "ellipsis")
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private var dismissGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 220 {
                    dismiss()
                } else {
                    dragOffset = 0
                }
            }
    }

    private var applePodcastsFallbackURL: URL {
        URL(string: "https://podcasts.apple.com")!
    }

    private func loadArtifacts() async {
        guard let episode = player.currentEpisode else { return }
        do {
            let transcript = try await client.transcript(for: episode.stableID)
            transcriptText = TranscriptRenderer.render(segmentsJSON: transcript.segmentsJSON)
        } catch {
            transcriptText = nil
        }
        do {
            let artifact = try await client.chapters(for: episode.stableID)
            chapters = ChapterRenderer.render(chaptersJSON: artifact.chaptersJSON)
        } catch {
            chapters = []
        }
    }

    private func currentArtworkURL(for episode: EpisodeDTO) -> URL? {
        chapters
            .last { $0.start <= player.elapsed }
            .flatMap(\.displayImageURL) ?? episode.imageURL.flatMap(URL.init)
    }

    private func isPlayed(_ episode: EpisodeDTO) -> Bool {
        LibraryStore.isPlayed(episode, in: modelContext)
    }

    private func togglePlayed(_ episode: EpisodeDTO) {
        if isPlayed(episode) {
            LibraryStore.markUnplayed(episode, in: modelContext)
        } else {
            LibraryStore.markPlayed(episode, in: modelContext)
        }
    }
}

private enum NowPlayingPage: Hashable {
    case transcript
    case artwork
    case details
}

private struct NowPlayingTranscriptPage: View {
    let transcriptText: String?

    var body: some View {
        ScrollView {
            if let transcriptText, !transcriptText.isEmpty {
                Text(transcriptText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                ContentUnavailableView("No Transcript", systemImage: "text.quote")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

private struct NowPlayingEpisodeDetailsPage: View {
    let episode: EpisodeDTO
    let chapters: [EpisodeChapterDTO]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let summary = episode.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.body)
                } else {
                    ContentUnavailableView("No Episode Notes", systemImage: "doc.text")
                        .foregroundStyle(.secondary)
                }

                if !chapters.isEmpty {
                    Text("Chapters")
                        .font(.headline)
                    ForEach(chapters) { chapter in
                        HStack {
                            Text(format(chapter.start))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(chapter.title)
                                .font(.subheadline)
                            Spacer()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private func format(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded()))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

private struct NowPlayingProgressView: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        VStack {
            Slider(
                value: Binding(get: { progress }, set: { player.seek(to: $0) })
            ) {
                Text("Playback position")
            }
            .disabled(player.duration == nil)
            .tint(.orange)

            HStack {
                Text(format(player.elapsed))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Text("-\(format(remaining))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private var progress: Double {
        guard let d = player.duration, d > 0 else { return 0 }
        return min(1, max(0, player.elapsed / d))
    }

    private var remaining: TimeInterval {
        guard let d = player.duration else { return 0 }
        return max(0, d - player.elapsed)
    }

    private func format(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "--:--" }
        let total = max(0, Int(value.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? "\(h):" + String(format: "%02d:%02d", m, s) : "\(m):" + String(format: "%02d", s)
    }
}

private struct SpeedPickerSheet: View {
    @EnvironmentObject private var player: PlayerController
    @Environment(\.dismiss) private var dismiss
    private let speeds: [Float] = [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0]

    var body: some View {
        NavigationStack {
            List(speeds, id: \.self) { speed in
                Button {
                    player.speed = speed
                    dismiss()
                } label: {
                    HStack {
                        Text(String(format: "%.2g×", speed))
                            .monospacedDigit()
                        Spacer()
                        if speed == player.speed {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Playback Speed")
        }
    }
}

private struct AVRoutePickerViewRepresented: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.activeTintColor = .label
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
