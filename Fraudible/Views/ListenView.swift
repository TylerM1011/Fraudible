import SwiftUI

/// Now Playing: big artwork over a blurred backdrop of the cover, a scrubber, and Liquid Glass
/// transport controls. Chapters, speed and the LibriVox torrent link are one tap away.
struct ListenView: View {
    @Environment(AudiobookPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    /// While dragging the scrubber, show where you'll land instead of the live position.
    @State private var scrubbing: Double?
    @State private var showChapters = false

    var body: some View {
        NavigationStack {
            Group {
                if let book = player.book {
                    content(book)
                } else {
                    ContentUnavailableView("Nothing Playing", systemImage: "headphones")
                }
            }
            .background { backdrop }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Label("Close", systemImage: "chevron.down")
                    }
                }
                if let book = player.book {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Chapters", systemImage: "list.bullet") { showChapters = true }
                            if book.source == .librivox, let origin = book.origin {
                                ShareLink(item: Catalog.audiobookTorrentURL(identifier: origin.sourceId), subject: Text("\(book.title) (torrent)")) {
                                    Label("Share Torrent Link", systemImage: "arrow.down.doc")
                                }
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis")
                        }
                    }
                }
            }
            .sheet(isPresented: $showChapters) {
                if let book = player.book {
                    ChapterList(book: book)
                        .presentationDetents([.medium, .large])
                }
            }
        }
    }

    /// The cover, blurred and enlarged, behind everything — like Apple Music.
    @ViewBuilder private var backdrop: some View {
        ZStack {
            Color(.systemBackground)
            if let url = player.book?.coverImageURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    }
                }
                .blur(radius: 70)
                .opacity(0.55)
                .scaleEffect(1.3)
            }
        }
        .ignoresSafeArea()
    }

    private func content(_ book: LibraryBook) -> some View {
        let shown = scrubbing ?? player.currentTime
        let duration = max(player.duration, 1)

        return VStack(spacing: 22) {
            Spacer(minLength: 0)
            Cover(url: book.coverImageURL, title: book.title, kind: .audiobook, width: 230, cornerRadius: 14)
                .scaleEffect(player.isPlaying ? 1 : 0.92)
                .animation(.spring(duration: 0.45, bounce: 0.25), value: player.isPlaying)

            VStack(spacing: 4) {
                Text(book.title)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(book.author)
                    .font(.body)
                    .foregroundStyle(.secondary)
                Button { showChapters = true } label: {
                    Text(player.currentTrack?.title ?? "")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                .tint(.orange)
                .padding(.top, 2)
            }
            .padding(.horizontal)

            VStack(spacing: 4) {
                Slider(
                    value: Binding(get: { min(shown, duration) }, set: { scrubbing = $0 }),
                    in: 0...duration,
                    onEditingChanged: { editing in
                        if !editing, let target = scrubbing {
                            player.seek(to: target)
                            scrubbing = nil
                        }
                    }
                )
                .accessibilityLabel("Position")
                .accessibilityValue(formatTime(shown))
                HStack {
                    Text(formatTime(shown))
                    Spacer()
                    Text("-\(formatTime(max(0, player.duration - shown)))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)

            transport

            HStack(spacing: 12) {
                Menu {
                    Picker("Speed", selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                        ForEach(AudiobookPlayer.rates, id: \.self) { rate in
                            Text(rateLabel(rate)).tag(rate)
                        }
                    }
                } label: {
                    Label(rateLabel(player.rate), systemImage: "gauge.with.dots.needle.67percent")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Playback speed, \(rateLabel(player.rate))")

                Button { showChapters = true } label: {
                    Label("Chapter \(player.trackIndex + 1) of \(book.tracks?.count ?? 0)", systemImage: "list.bullet")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 12)
    }

    /// Previous / back 30 / play-pause / forward 30 / next, as glass circles that blend together.
    private var transport: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                glassButton("backward.end.fill", size: 48, label: "Previous chapter", action: player.previousTrack)
                glassButton("gobackward.30", size: 56, label: "Back 30 seconds") { player.seek(by: -30) }
                Button(action: player.toggle) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(.white)
                        .frame(width: 78, height: 78)
                        .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                glassButton("goforward.30", size: 56, label: "Forward 30 seconds") { player.seek(by: 30) }
                glassButton("forward.end.fill", size: 48, label: "Next chapter", action: player.nextTrack)
            }
        }
    }

    private func glassButton(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The chapter list, with the current one marked.
private struct ChapterList: View {
    let book: LibraryBook
    @Environment(AudiobookPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array((book.tracks ?? []).enumerated()), id: \.offset) { index, track in
                        let active = index == player.trackIndex
                        Button {
                            player.open(book, track: index, seconds: 0)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Group {
                                    if active {
                                        Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                                            .foregroundStyle(Color.accentColor)
                                    } else {
                                        Text("\(index + 1)").foregroundStyle(.secondary)
                                    }
                                }
                                .font(.subheadline.monospacedDigit())
                                .frame(width: 28)
                                Text(track.title)
                                    .fontWeight(active ? .semibold : .regular)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let d = track.duration {
                                    Text(formatTime(d))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .onAppear { proxy.scrollTo(player.trackIndex, anchor: .center) }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
