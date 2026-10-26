import PDFKit
import SwiftUI

/// Reads an ebook aloud with Apple's built-in voices or Kokoro, highlighting each paragraph.
/// The text fills the screen; the controls float over it on a Liquid Glass bar.
struct ReaderView: View {
    let bookID: String
    @Environment(Library.self) private var library
    @Environment(KokoroManager.self) private var kokoro
    @Environment(AppRouter.self) private var router
    @State private var session: ReaderSession?
    @State private var showVoices = false
    @State private var showPDF = false

    var body: some View {
        Group {
            if let book = library.book(bookID) {
                if let session {
                    ReaderContent(book: book, session: session, showVoices: $showVoices)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("Book Removed", systemImage: "book.closed", description: Text("This book isn’t in your library any more."))
            }
        }
        .navigationTitle(library.book(bookID)?.title ?? "Reader")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if library.book(bookID)?.pdfFileURL != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPDF = true } label: {
                        Label("View Original PDF", systemImage: "doc.richtext")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showVoices = true } label: {
                    Label("Voice", systemImage: "person.wave.2")
                }
            }
        }
        .sheet(isPresented: $showPDF) {
            if let book = library.book(bookID), let url = book.pdfFileURL {
                PDFSheet(url: url, title: book.title)
            }
        }
        .sheet(isPresented: $showVoices) {
            if let session {
                VoicePicker(session: session)
                    .presentationDetents([.medium, .large])
            }
        }
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
    }
}

private struct ReaderContent: View {
    let book: LibraryBook
    @Bindable var session: ReaderSession
    @Binding var showVoices: Bool
    @Environment(KokoroManager.self) private var kokoro
    @AppStorage("fraudible.kokoroHintDismissed") private var hintDismissed = false

    var body: some View {
        Group {
            if let error = session.loadError {
                ContentUnavailableView("Couldn’t Open Book", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let paragraphs = session.paragraphs {
                text(paragraphs)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { dock }
        .alert("Couldn’t Read Aloud", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    private func text(_ paragraphs: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(paragraphs.indices, id: \.self) { i in
                        let active = i == session.index
                        Text(Self.highlighted(paragraphs[i], word: active ? session.word : nil))
                            .font(.system(size: 19, design: .serif))
                            .lineSpacing(7)
                            .foregroundStyle(active ? .primary : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                if active {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.12))
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { session.tapParagraph(i) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Read from here")
                            .id(i)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
                .animation(.smooth(duration: 0.25), value: session.index)
            }
            .onAppear { proxy.scrollTo(session.index, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            // Keep the current paragraph in view.
            .onChange(of: session.index) { _, i in
                withAnimation(.smooth) { proxy.scrollTo(i, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            }
        }
    }

    /// The paragraph with the word being spoken marked.
    private static func highlighted(_ text: String, word: Range<Int>?) -> AttributedString {
        var attributed = AttributedString(text)
        guard let word, word.lowerBound >= 0, word.upperBound <= text.utf16.count, !word.isEmpty else { return attributed }
        let lower = String.Index(utf16Offset: word.lowerBound, in: text)
        let upper = String.Index(utf16Offset: word.upperBound, in: text)
        if let range = Range(lower..<upper, in: attributed) {
            attributed[range].backgroundColor = Color.accentColor.opacity(0.35)
            attributed[range].foregroundColor = .primary
        }
        return attributed
    }

    // MARK: - Floating controls

    private var dock: some View {
        VStack(spacing: 12) {
            engineCard

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Menu {
                        Picker("Speed", selection: Binding(get: { session.rate }, set: { session.setRate($0) })) {
                            ForEach(ReaderSession.rates, id: \.self) { rate in
                                Text(rateLabel(rate)).tag(rate)
                            }
                        }
                    } label: {
                        Text(rateLabel(session.rate))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .frame(width: 48, height: 48)
                            .contentShape(.circle)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .accessibilityLabel("Speed, \(rateLabel(session.rate))")

                    circleButton("backward.fill", label: "Previous paragraph") { session.jump(-1) }

                    Button(action: session.togglePlay) {
                        ZStack {
                            if session.isPlaying && (session.preparingVoice || session.buffering) {
                                // Still preparing audio; tapping here pauses.
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 26, weight: .semibold))
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 68, height: 68)
                        // The whole circle is the button, not just the icon; otherwise taps fall
                        // through to the paragraph underneath and restart reading.
                        .contentShape(.circle)
                        .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(session.isPlaying ? "Pause" : "Read aloud")

                    circleButton("forward.fill", label: "Next paragraph") { session.jump(1) }

                    Button { showVoices = true } label: {
                        Image(systemName: session.voice.engine == .kokoro ? "sparkles" : "person.wave.2")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 48, height: 48)
                            .contentShape(.circle)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Voice: \(session.voice.name)")
                }
            }

            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .contentShape(.rect)
        .onTapGesture {} // taps between the buttons shouldn't land on the text behind
    }

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 52, height: 52)
                .contentShape(.circle)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var statusLine: String {
        let count = session.paragraphs.map { String($0.count) } ?? "…"
        if let word = session.pausedWord {
            return "Paused on “\(word)” · tap play to continue from here"
        }
        let prefix = session.reading && session.buffering ? "Preparing audio · " : ""
        return "\(prefix)\(session.voice.name) · Paragraph \(session.index + 1) of \(count) · \(Int(session.progress * 100))%"
    }

    // MARK: - Kokoro cards

    @ViewBuilder private var engineCard: some View {
        if session.preparingVoice {
            card {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading the Kokoro voice…").font(.subheadline.weight(.medium))
                }
            }
        } else if session.pendingVoice != nil || kokoro.status == .downloading {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    switch kokoro.status {
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                        Button("Try Again") { kokoro.download() }
                            .buttonStyle(.glassProminent)
                    default:
                        HStack {
                            Label("Downloading Kokoro", systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(Int(kokoro.progress * 100))%")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: kokoro.progress)
                        HStack {
                            Text("Keep listening with the current voice meanwhile.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { kokoro.cancelDownload() }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.glass)
                        }
                    }
                }
            }
        } else if session.voice.engine == .apple, KokoroManager.isSupported, !kokoro.isDownloaded, !hintDismissed {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Want a more natural voice?", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                    Text("Kokoro is a free neural voice that runs entirely on your iPhone. One-time download of \(KokoroManager.downloadSize).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Download") {
                            session.choose(VoiceCatalog.resolve(nil, kokoroAvailable: true))
                        }
                        .buttonStyle(.glassProminent)
                        Button("Not Now") { withAnimation { hintDismissed = true } }
                            .buttonStyle(.glass)
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

/// Choose between Kokoro voices (natural, needs a one-time download) and Apple's built-in voices.
private struct VoicePicker: View {
    let session: ReaderSession
    @Environment(KokoroManager.self) private var kokoro
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
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Label("Kokoro", systemImage: "sparkles")
                } footer: {
                    Text("Natural neural voices that run on your iPhone. Uses more battery than Apple’s voices.")
                }

                Section {
                    ForEach(appleVoices) { voice in row(voice) }
                } header: {
                    Label("Apple", systemImage: "apple.logo")
                } footer: {
                    Text("Get more natural Apple voices (Enhanced and Premium) in Settings › Accessibility › Spoken Content › Voices › English.")
                }
            }
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
                Text("Downloading… \(Int(kokoro.progress * 100))%").font(.subheadline)
                ProgressView(value: kokoro.progress)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
        default:
            if kokoro.isDownloaded {
                Button("Delete Kokoro Voice (\(KokoroManager.downloadSize))", role: .destructive) { confirmDelete = true }
            } else {
                Text("Pick a voice to download Kokoro (\(KokoroManager.downloadSize), one time).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                    Text(voice.name).foregroundStyle(.primary)
                    Text("\(voice.accent) · \(voice.detail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if needsDownload {
                    Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary)
                }
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor).fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The original scanned PDF of an Open Library book, with a button to share or save it.
/// Reading aloud carries on while it's open.
private struct PDFSheet: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PDFKitView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: url) { Label("Share PDF", systemImage: "square.and.arrow.up") }
                    }
                }
        }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}
