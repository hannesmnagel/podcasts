import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        if let episode = player.currentEpisode {
            HStack(spacing: 12) {
                Button(action: player.togglePlayPause) {
                    Image(systemName: "playpause.fill")
                }
                VStack(alignment: .leading) {
                    Text(episode.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Slider(value: Binding(get: { Double(player.speed) }, set: { player.speed = Float($0) }), in: 1...5, step: 0.1) {
                        Text("Speed")
                    } minimumValueLabel: {
                        Text("1x")
                    } maximumValueLabel: {
                        Text("5x")
                    }
                }
                Text(player.speed, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit()
                    + Text("x")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}
