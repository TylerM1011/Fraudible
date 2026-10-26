import SwiftUI

/// Full audiobook player: chapters, seeking, speed, and the torrent link for LibriVox items.
struct ListenView: View {
    @Environment(AudiobookPlayer.self) private var player
    @Environment(\.palette) private var c
    @Environment(\.dismiss) private var dismiss
    /// While dragging the seek bar, show where you'll land instead of the live position.
    @State private var scrubbing: Double?

    var body: some View {
        NavigationStack {
            Group {
                if let book = player.book {
                    content(book)
                } else {
                    Text("Nothing is playing.")
                        .foregroundStyle(c.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(c.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Now playing").font(.mono(17, weight: .heavy)).foregroundStyle(c.text)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.font(.mono(15)).tint(c.text)
                }
                if let book = player.book, book.source == .librivox, let origin = book.origin {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: Catalog.audiobookTorrentURL(identifier: origin.sourceId), subject: Text("\(book.title) (torrent)")) {
                            Text("Torrent").font(.mono(14)).textCase(.uppercase).foregroundStyle(c.accent)
                        }
                    }
                }
            }
            .retroNavigation(c)
        }
    }

    private func content(_ book: LibraryBook) -> some View {
        let shown = scrubbing ?? player.currentTime
        let duration = player.duration
        let fraction = duration > 0 ? min(1, shown / duration) : 0

        return VStack(spacing: 0) {
            VStack(spacing: 6) {
                Cover(url: book.coverImageURL, title: book.title, size: 150)
                Text(book.title)
                    .font(.mono(20, weight: .heavy))
                    .foregroundStyle(c.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.top, 10)
                Text(book.author).font(.system(size: 14)).foregroundStyle(c.muted)
                Text(player.currentTrack?.title ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(c.audiobook)
                    .lineLimit(1)
                    .padding(.top, 4)
            }
            .padding(.top, 8)

            seekBar(fraction: fraction, duration: duration)
                .padding(.top, 16)
            HStack {
                Text(formatTime(shown))
                Spacer()
                Text("-\(formatTime(max(0, duration - shown)))")
            }
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(c.faint)

            HStack {
                RoundButton(label: Glyph.prev, accessibilityLabel: "Previous chapter", action: player.previousTrack)
                Spacer()
                RoundButton(label: "-30", accessibilityLabel: "Back 30 seconds") { player.seek(by: -30) }
                Spacer()
                RoundButton(label: player.isPlaying ? Glyph.pause : Glyph.play, big: true,
                            accessibilityLabel: player.isPlaying ? "Pause" : "Play", action: player.toggle)
                Spacer()
                RoundButton(label: "+30", accessibilityLabel: "Forward 30 seconds") { player.seek(by: 30) }
                Spacer()
                RoundButton(label: Glyph.next, accessibilityLabel: "Next chapter", action: player.nextTrack)
            }
            .padding(.top, 16)

            Button(action: player.cycleRate) {
                Text("\(rateLabel(player.rate))× speed")
                    .font(.mono(13))
                    .foregroundStyle(c.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(c.border, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
            .accessibilityLabel("Change speed")

            SectionLabel(text: "Chapters")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 20)
                .padding(.bottom, 6)
            chapters(book)
        }
        .padding(.horizontal, 20)
    }

    private func seekBar(fraction: Double, duration: Double) -> some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    c.surfaceHigh
                    c.accent.frame(width: width * fraction)
                }
                .frame(height: 4)
                .overlay(Rectangle().stroke(c.border, lineWidth: 1))
                RoundedRectangle(cornerRadius: 2)
                    .fill(c.accent)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(c.border, lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .offset(x: width * fraction - 7)
            }
            .frame(height: 32)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        scrubbing = min(1, max(0, value.location.x / width)) * duration
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        player.seek(to: min(1, max(0, value.location.x / width)) * duration)
                        scrubbing = nil
                    }
            )
        }
        .frame(height: 32)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(formatTime(player.currentTime))
        .accessibilityAdjustableAction { direction in
            player.seek(by: direction == .increment ? 30 : -30)
        }
    }

    private func chapters(_ book: LibraryBook) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array((book.tracks ?? []).enumerated()), id: \.offset) { index, track in
                        let active = index == player.trackIndex
                        Button {
                            player.open(book, track: index, seconds: 0)
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.system(size: 15).monospacedDigit())
                                    .foregroundStyle(active ? c.accent : c.faint)
                                    .frame(width: 28, alignment: .leading)
                                Text(track.title)
                                    .foregroundStyle(active ? c.accent : c.text)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let d = track.duration {
                                    Text(formatTime(d)).font(.system(size: 12).monospacedDigit()).foregroundStyle(c.faint)
                                }
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 8)
                            .background(active ? c.surfaceHigh : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(active ? c.border : .clear, lineWidth: 2))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(.bottom, 24)
            }
            .onAppear { proxy.scrollTo(player.trackIndex, anchor: .center) }
        }
    }

    private func rateLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", rate)
    }
}
