import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerController
    @Binding var showNowPlaying: Bool

    var body: some View {
        if let episode = player.currentEpisode {
            HStack {
                Button { showNowPlaying = true } label: {
                    HStack {
                        artworkImage(for: episode)
                        Text(episode.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                Button(action: player.togglePlayPause) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button { showNowPlaying = true } label: {
                    Image(systemName: "chevron.up")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Open Now Playing")
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func artworkImage(for episode: EpisodeDTO) -> some View {
        AsyncImage(url: episode.imageURL.flatMap(URL.init)) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.25)
                    .overlay {
                        Image(systemName: "waveform")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
