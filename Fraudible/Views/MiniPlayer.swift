import SwiftUI

/// Compact "now playing" bar in the tab bar's accessory slot. Tap it to open Now Playing.
/// When the tab bar shrinks on scroll it switches to its slimmer inline layout.
struct MiniPlayer: View {
    @Environment(AudiobookPlayer.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if let book = player.book {
            let inline = placement == .inline
            HStack(spacing: 10) {
                Cover(url: book.coverImageURL, title: book.title, kind: .audiobook, width: inline ? 22 : 28, cornerRadius: 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(book.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !inline, let chapter = player.currentTrack?.title {
                        Text(chapter)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: player.toggle) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                if !inline {
                    Button { player.seek(by: 30) } label: {
                        Image(systemName: "goforward.30")
                            .font(.title3)
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Forward 30 seconds")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
            .onTapGesture { router.showPlayer = true }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens Now Playing")
        } else {
            Text("Not playing")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}
