import SwiftUI

/// Search LibriVox audiobooks and Gutenberg ebooks; each result says how it will be read.
struct SearchView: View {
    @Environment(Library.self) private var library
    @Environment(AudiobookPlayer.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(\.palette) private var c

    private enum Filter: Hashable { case all, kind(BookKind) }

    private struct SourceState {
        var results: [SearchResult] = []
        var loading = false
        var error: String?
    }

    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var sources: [BookKind: SourceState] = [:]
    @State private var searched = ""
    @State private var tasks: [Task<Void, Never>] = []
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBox
            if searched.isEmpty {
                emptyState
            } else {
                results
            }
        }
        .background(c.bg)
        .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayer() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Fraudible").font(.mono(18, weight: .heavy)).foregroundStyle(c.text)
            }
            ToolbarItem(placement: .topBarTrailing) { ThemeToggle() }
        }
        .retroNavigation(c)
    }

    // MARK: - Pieces

    private var searchBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("", text: $query, prompt: Text("Search titles or authors, e.g. Sherlock Holmes").foregroundStyle(c.faint))
                .focused($fieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(runSearch)
                .font(.system(size: 16))
                .foregroundStyle(c.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(c.surface)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(c.border, lineWidth: 2))

            HStack(spacing: 8) {
                chip("All", value: .all, tint: c.accent)
                chip("Audiobooks", value: .kind(.audiobook), tint: c.audiobook)
                chip("Text-to-speech", value: .kind(.tts), tint: c.tts)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func chip(_ label: String, value: Filter, tint: Color) -> some View {
        let active = filter == value
        return Button {
            filter = value
        } label: {
            Text(label)
                .font(.mono(12))
                .textCase(.uppercase)
                .foregroundStyle(active ? tint : c.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(active ? tint.opacity(0.15) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(active ? tint : c.border, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Find something to listen to")
                    .font(.mono(22, weight: .heavy))
                    .foregroundStyle(c.text)
                Text("Results are labelled \(Text("Audiobook").bold().foregroundStyle(c.audiobook)) (human narration) or \(Text("Text-to-speech").bold().foregroundStyle(c.tts)) (an ebook read aloud by your phone). Everything downloads for offline listening.")
                    .font(.system(size: 15))
                    .foregroundStyle(c.muted)
                    .lineSpacing(4)
                Text("The catalogue is public-domain books, so think classics: Austen, Dickens, Doyle, Shelley, Twain…")
                    .font(.system(size: 15))
                    .foregroundStyle(c.muted)
                    .lineSpacing(4)
            }
            .padding(24)
            .padding(.top, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var visibleKinds: [BookKind] {
        switch filter {
        case .all: [.audiobook, .tts]
        case .kind(let kind): [kind]
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleKinds, id: \.self) { kind in
                    sectionHeader(kind)
                    ForEach(sources[kind]?.results ?? []) { item in
                        ResultRow(item: item, book: library.book(forKey: item.key)) { action in
                            perform(action, on: item)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func sectionHeader(_ kind: BookKind) -> some View {
        let state = sources[kind] ?? SourceState()
        let info: (title: String, note: String) = kind == .audiobook
            ? ("Audiobooks", "Read by human volunteers · LibriVox")
            : ("Text-to-speech", "Ebooks read aloud by your phone · Project Gutenberg")
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                SectionLabel(text: state.loading ? info.title : "\(info.title) · \(state.results.count)", color: c.kind(kind))
                if state.loading { ProgressView().tint(c.kind(kind)).controlSize(.small) }
            }
            Text(info.note).font(.system(size: 12)).foregroundStyle(c.faint)
            if let error = state.error {
                Text(error).font(.system(size: 13)).foregroundStyle(c.danger).padding(.top, 4)
            } else if !state.loading && state.results.isEmpty {
                Text("No matches for “\(searched)”.").font(.system(size: 12)).foregroundStyle(c.faint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    // MARK: - Actions

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        tasks.forEach { $0.cancel() }
        searched = q
        sources = [.audiobook: SourceState(loading: true), .tts: SourceState(loading: true)]

        // Each catalogue fills in its own section as soon as it answers.
        tasks = BookKind.allCases.map { kind in
            Task {
                do {
                    let found = try await kind == .audiobook ? Catalog.searchAudiobooks(q) : Catalog.searchEbooks(q)
                    guard !Task.isCancelled else { return }
                    sources[kind] = SourceState(results: found)
                } catch {
                    guard !Task.isCancelled else { return }
                    let base = kind == .audiobook ? "Couldn’t reach LibriVox right now." : "Couldn’t reach Project Gutenberg right now."
                    var slow = false
                    if case .timedOut? = error as? Catalog.CatalogError { slow = true }
                    sources[kind] = SourceState(error: slow ? "\(base) It took too long to respond." : base)
                }
            }
        }
    }

    private func perform(_ action: ResultRow.Action, on item: SearchResult) {
        switch action {
        case .download:
            library.download(item)
        case .retry:
            if let book = library.book(forKey: item.key) { library.retry(book.id) }
        case .open:
            if let book = library.book(forKey: item.key) { router.open(book, player: player) }
        }
    }
}

/// One search result with its download state and action button.
private struct ResultRow: View {
    enum Action { case download, retry, open }

    let item: SearchResult
    let book: LibraryBook?
    let onAction: (Action) -> Void
    @Environment(\.palette) private var c

    var body: some View {
        HStack(spacing: 12) {
            Cover(url: item.coverURL, title: item.title, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                KindBadge(kind: item.kind)
                Text(item.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(c.text)
                    .lineLimit(2)
                Text(item.author)
                    .font(.system(size: 13))
                    .foregroundStyle(c.muted)
                    .lineLimit(1)
                let meta = [item.runtime.map { "\($0) long" }, item.language?.uppercased()].compactMap { $0 }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(c.faint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var action: some View {
        switch book?.status {
        case nil:
            Button("Download") { onAction(.download) }.buttonStyle(RetroButtonStyle(small: true))
        case .downloading:
            VStack(spacing: 6) {
                Text("\(Int((book?.progress ?? 0) * 100))%").font(.system(size: 12)).foregroundStyle(c.faint)
                ProgressBar(value: book?.progress ?? 0, color: c.kind(item.kind))
            }
            .frame(width: 84)
        case .error:
            Button("Retry") { onAction(.retry) }.buttonStyle(RetroButtonStyle(variant: .danger, small: true))
        case .ready:
            Button(item.kind == .audiobook ? "Listen" : "Read") { onAction(.open) }
                .buttonStyle(RetroButtonStyle(variant: .ghost, small: true))
        }
    }
}
