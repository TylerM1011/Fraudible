import SwiftUI

/// Reads an ebook aloud with Apple's built-in voices or Kokoro, highlighting each paragraph.
struct ReaderView: View {
    let bookID: String
    @Environment(Library.self) private var library
    @Environment(KokoroManager.self) private var kokoro
    @Environment(AppRouter.self) private var router
    @Environment(\.palette) private var c
    @State private var session: ReaderSession?
    @State private var showVoices = false

    var body: some View {
        Group {
            if let book = library.book(bookID) {
                if let session {
                    ReaderContent(book: book, session: session, showVoices: $showVoices)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text("This book isn’t in your library any more.")
                    .foregroundStyle(c.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(c.bg)
        .navigationTitle(library.book(bookID)?.title ?? "Reader")
        .navigationBarTitleDisplayMode(.inline)
        .retroNavigation(c)
        .onAppear {
            if session == nil, let book = library.book(bookID) {
                session = ReaderSession(book: book, library: library, kokoro: kokoro)
            }
        }
        .onDisappear {
            // Switching tabs also hides this screen; only stop reading when it was actually closed.
            let route = AppRouter.Route.reader(bookID)
            if !router.searchPath.contains(route) && !router.libraryPath.contains(route) { session?.stop() }
        }
        .onChange(of: kokoro.isDownloaded) { _, downloaded in
            if downloaded { session?.kokoroBecameAvailable() }
        }
        .sheet(isPresented: $showVoices) {
            if let session {
                VoicePicker(session: session)
                    .environment(\.palette, c)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

private struct ReaderContent: View {
    let book: LibraryBook
    @Bindable var session: ReaderSession
    @Binding var showVoices: Bool
    @Environment(KokoroManager.self) private var kokoro
    @Environment(\.palette) private var c
    @AppStorage("fraudible.kokoroHintDismissed") private var hintDismissed = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = session.loadError {
                Text(error).foregroundStyle(c.danger).padding(24).frame(maxHeight: .infinity)
            } else if let paragraphs = session.paragraphs {
                text(paragraphs)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            dock
        }
        .alert("Couldn’t read aloud", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    private func text(_ paragraphs: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(paragraphs.indices, id: \.self) { i in
                        let active = i == session.index
                        Text(paragraphs[i])
                            .font(.system(size: 17))
                            .lineSpacing(6)
                            .foregroundStyle(active ? c.text : c.muted)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(active ? c.tts.opacity(0.12) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                            .onTapGesture { session.tapParagraph(i) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Read from here")
                            .id(i)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
            .onAppear { proxy.scrollTo(session.index, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            // Keep the current paragraph in view.
            .onChange(of: session.index) { _, i in
                withAnimation { proxy.scrollTo(i, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            }
        }
    }

    // MARK: - Dock

    private var dock: some View {
        VStack(spacing: 12) {
            engineCard
            Text(statusLine)
                .font(.system(size: 12))
                .foregroundStyle(c.faint)
                .frame(maxWidth: .infinity)
            HStack(spacing: 28) {
                RoundButton(label: Glyph.prev, accessibilityLabel: "Previous paragraph") { session.jump(-1) }
                RoundButton(
                    label: session.isPlaying ? Glyph.pause : Glyph.play,
                    big: true,
                    accessibilityLabel: session.isPlaying ? "Pause" : "Read aloud",
                    action: session.togglePlay
                )
                RoundButton(label: Glyph.next, accessibilityLabel: "Next paragraph") { session.jump(1) }
            }
            HStack(spacing: 10) {
                pill("\(rateLabel(session.rate))× speed", action: session.cycleRate)
                pill("\(session.voice.name) · \(session.voice.accent)") { showVoices = true }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(c.surface)
        .overlay(alignment: .top) { c.border.frame(height: 2) }
    }

    private var statusLine: String {
        let total = session.paragraphs?.count
        let prefix = session.reading && session.buffering ? "Preparing audio… · " : ""
        let count = total.map(String.init) ?? "…"
        return "\(prefix)Paragraph \(session.index + 1) of \(count) · \(Int(session.progress * 100))%"
    }

    @ViewBuilder private var engineCard: some View {
        if session.preparingVoice {
            card {
                HStack(spacing: 10) {
                    ProgressView().tint(c.tts)
                    Text("Loading the Kokoro voice…").font(.mono(15)).foregroundStyle(c.text)
                }
            }
        } else if session.pendingVoice != nil || kokoro.status == .downloading {
            kokoroDownloadCard
        } else if session.voice.engine == .apple, KokoroManager.isSupported, !kokoro.isDownloaded, !hintDismissed {
            card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Want a more natural voice?").font(.mono(15)).foregroundStyle(c.text)
                    Text("Kokoro is a free neural voice that runs entirely on your phone. It’s a one-time download of \(KokoroManager.downloadSize).")
                        .font(.system(size: 13))
                        .foregroundStyle(c.muted)
                    HStack {
                        Button("Download Kokoro") {
                            session.choose(VoiceCatalog.resolve(nil, kokoroAvailable: true))
                        }
                        .buttonStyle(RetroButtonStyle(small: true))
                        Button("Not now") { hintDismissed = true }
                            .buttonStyle(RetroButtonStyle(variant: .ghost, small: true))
                    }
                }
            }
        }
    }

    private var kokoroDownloadCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                switch kokoro.status {
                case .failed(let message):
                    Text(message).font(.system(size: 13)).foregroundStyle(c.danger)
                    Button("Try again") { kokoro.download() }.buttonStyle(RetroButtonStyle(small: true))
                default:
                    Text("Downloading the Kokoro voice… \(Int(kokoro.progress * 100))%").font(.mono(15)).foregroundStyle(c.text)
                    ProgressBar(value: kokoro.progress, color: c.tts)
                    Text("You can keep listening with the current voice meanwhile.")
                        .font(.system(size: 12))
                        .foregroundStyle(c.muted)
                    Button("Cancel") { kokoro.cancelDownload() }.buttonStyle(RetroButtonStyle(variant: .ghost, small: true))
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(c.surfaceHigh)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(c.border, lineWidth: 2))
    }

    private func pill(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.mono(13))
                .foregroundStyle(c.text)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(c.border, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func rateLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", rate)
    }
}

/// Choose between Kokoro voices (natural, needs a one-time download) and Apple's built-in voices.
private struct VoicePicker: View {
    let session: ReaderSession
    @Environment(KokoroManager.self) private var kokoro
    @Environment(\.palette) private var c
    @Environment(\.dismiss) private var dismiss
    @State private var appleVoices: [ReaderVoice] = []
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if KokoroManager.isSupported {
                        kokoroStatus
                        ForEach(VoiceCatalog.kokoro) { voice in row(voice) }
                    } else {
                        Text("Kokoro needs a real iPhone; it can’t run in the Simulator.")
                            .font(.system(size: 13)).foregroundStyle(c.muted)
                    }
                } header: {
                    SectionLabel(text: "Kokoro · natural, on-device")
                }

                Section {
                    ForEach(appleVoices) { voice in row(voice) }
                } header: {
                    SectionLabel(text: "Apple voices · built in")
                } footer: {
                    Text("Get more natural Apple voices (Enhanced and Premium) in Settings › Accessibility › Spoken Content › Voices › English.")
                        .font(.system(size: 12))
                        .foregroundStyle(c.faint)
                }
            }
            .scrollContentBackground(.hidden)
            .background(c.surface)
            .navigationTitle("Choose a voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(c.accent)
                }
            }
            .confirmationDialog("Delete the Kokoro voice?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete \(KokoroManager.downloadSize)", role: .destructive) {
                    if session.voice.engine == .kokoro {
                        session.choose(VoiceCatalog.resolve(nil, kokoroAvailable: false))
                    }
                    kokoro.deleteModel()
                }
            } message: {
                Text("You can download it again any time.")
            }
        }
        .onAppear { appleVoices = VoiceCatalog.apple() }
    }

    @ViewBuilder private var kokoroStatus: some View {
        switch kokoro.status {
        case .downloading:
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading… \(Int(kokoro.progress * 100))%").font(.system(size: 13)).foregroundStyle(c.text)
                ProgressBar(value: kokoro.progress, color: c.tts)
            }
        case .failed(let message):
            Text(message).font(.system(size: 13)).foregroundStyle(c.danger)
        default:
            if kokoro.isDownloaded {
                Button("Delete Kokoro voice (\(KokoroManager.downloadSize))", role: .destructive) { confirmDelete = true }
                    .font(.system(size: 13))
            } else {
                Text("Pick a voice to download Kokoro (\(KokoroManager.downloadSize), one time). Needs a recent iPhone; uses more battery than Apple’s voices.")
                    .font(.system(size: 13))
                    .foregroundStyle(c.muted)
            }
        }
    }

    private func row(_ voice: ReaderVoice) -> some View {
        let selected = voice.id == session.voice.id || voice.id == session.pendingVoice?.id
        let needsDownload = voice.engine == .kokoro && !kokoro.isDownloaded
        return Button {
            session.choose(voice)
            if !needsDownload { dismiss() }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selected ? "✓ " : "")\(voice.name)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selected ? c.tts : c.text)
                    Text("\(voice.accent) · \(voice.detail)\(needsDownload ? " · needs download" : "")")
                        .font(.system(size: 13))
                        .foregroundStyle(c.muted)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(c.surfaceHigh)
    }
}
