import AVKit
import SwiftUI

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerController
    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color(white: 0.1).ignoresSafeArea()

            VStack {
                dragHandle

                if let episode = player.currentEpisode {
                    Spacer(minLength: 0)
                    episodeTitle(episode)
                        .padding(.horizontal)
                    artwork(episode)
                        .padding(.horizontal)
                    Spacer(minLength: 0)
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
        .offset(y: max(0, dragOffset))
    }

    private var dragHandle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.5))
            .frame(width: 36, height: 5)
            .padding(.top, 10)
            .gesture(dismissGesture)
    }

    private func episodeTitle(_ episode: EpisodeDTO) -> some View {
        Text(episode.title)
            .font(.headline)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top)
    }

    private func artwork(_ episode: EpisodeDTO) -> some View {
        AsyncImage(url: episode.imageURL.flatMap(URL.init)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            default:
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
        .gesture(dismissGesture)
    }

    private var playbackControls: some View {
        HStack {
            Spacer()
            Button { player.seek(by: -15) } label: {
                Image(systemName: "gobackward.15")
                    .font(.title)
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 52))
            }
            Spacer()
            Button { player.seek(by: 30) } label: {
                Image(systemName: "goforward.30")
                    .font(.title)
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
            SpeedCycleButton()
            Spacer()
            AVRoutePickerViewRepresented()
                .frame(width: 44, height: 44)
            Spacer()
            Button {} label: {
                Image(systemName: "ellipsis")
                    .font(.title2)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .foregroundStyle(.primary)
    }

    private var dismissGesture: some Gesture {
        DragGesture()
            .updating($dragOffset) { value, state, _ in
                if value.translation.height > 0 { state = value.translation.height }
            }
            .onEnded { value in
                if value.translation.height > 100 { dismiss() }
            }
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

private struct SpeedCycleButton: View {
    @EnvironmentObject private var player: PlayerController
    private let speeds: [Float] = [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0]

    var body: some View {
        Button { cycleSpeed() } label: {
            Text(String(format: "%.2g×", player.speed))
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(minWidth: 52)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .foregroundStyle(.primary)
    }

    private func cycleSpeed() {
        player.speed = speeds.first { $0 > player.speed } ?? speeds[0]
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
