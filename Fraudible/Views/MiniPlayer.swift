import SwiftUI

/// Compact "now playing" bar shown at the bottom of the tab screens.
struct MiniPlayer: View {
    @Environment(AudiobookPlayer.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(\.palette) private var c

    var body: some View {
        if let book = player.book {
            VStack(spacing: 0) {
                ProgressBar(value: player.fraction, height: 2)
                HStack(spacing: 12) {
                    Cover(url: book.coverImageURL, title: book.title, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(c.text)
                            .lineLimit(1)
                        Text(player.currentTrack?.title ?? "")
                            .font(.mono(12, weight: .regular))
                            .foregroundStyle(c.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: player.toggle) {
                        Text(player.isPlaying ? Glyph.pause : Glyph.play)
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(c.accentText)
                            .frame(width: 40, height: 40)
                            .background(c.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(c.border, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(c.surfaceHigh)
            .overlay(alignment: .top) { c.border.frame(height: 2) }
            .contentShape(Rectangle())
            .onTapGesture { router.showPlayer = true }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Open player")
        }
    }
}
