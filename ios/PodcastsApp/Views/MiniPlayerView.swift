import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        if let episode = player.currentEpisode {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button(action: player.togglePlayPause) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                    Button("Back 15", systemImage: "gobackward.15") { player.seek(by: -15) }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Skip back 15 seconds")

                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        PlaybackProgressView()
                    }

                    Button("Forward 30", systemImage: "goforward.30") { player.seek(by: 30) }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Skip forward 30 seconds")
                }

                HStack(spacing: 10) {
                    Text("Speed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(player.speed) }, set: { player.speed = Float($0) }), in: 1...5, step: 0.1) {
                        Text("Playback speed")
                    } minimumValueLabel: {
                        Text("1x")
                    } maximumValueLabel: {
                        Text("5x")
                    }
                    Text("\(player.speed, format: .number.precision(.fractionLength(1)))x")
                        .monospacedDigit()
                }
                .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

private struct PlaybackProgressView: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        HStack(spacing: 8) {
            Text(format(player.elapsed))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { currentProgress },
                set: { newValue in player.seek(to: newValue) }
            )) {
                Text("Playback position")
            }
            .disabled(player.duration == nil)
            Text(format(player.duration ?? 0))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
    }

    private var currentProgress: Double {
        guard let duration = player.duration, duration > 0 else { return 0 }
        return min(1, max(0, player.elapsed / duration))
    }

    private func format(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "--:--" }
        let total = max(0, Int(value.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return "\(hours):" + String(format: "%02d:%02d", minutes, seconds) }
        return "\(minutes):" + String(format: "%02d", seconds)
    }
}
