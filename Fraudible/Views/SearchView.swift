import SwiftUI

/// Search LibriVox audiobooks, Gutenberg ebooks and Open Library scans, all at once.
/// The search field lives in the tab bar (this is the search tab).
struct SearchView: View {
    @Environment(Library.self) private var library
    @Environment(AudiobookPlayer.self) private var player
    @Environment(AppRouter.self) private var router

    private enum Filter: Hashable { case all, kind(BookKind) }

    /// Each catalogue gets its own section and fills it in as soon as it answers.
    private enum CatalogSection: CaseIterable {
        case librivox, gutenberg, openLibrary

        var kind: BookKind { self == .librivox ? .audiobook : .tts }

        var title: String {
            switch self {
            case .librivox: "Audiobooks"
            case .gutenberg: "Ebooks"
            case .openLibrary: "Scanned Books"
            }
        }

        var note: String {
            switch self {
            case .librivox: "Read by volunteers · LibriVox"
            case .gutenberg: "Read aloud on your phone · Project Gutenberg"
            case .openLibrary: "Original PDF scans, read aloud · Open Library"
            }
        }

        var unreachable: String {
            switch self {
            case .librivox: "Couldn’t reach LibriVox right now."
            case .gutenberg: "Couldn’t reach Project Gutenberg right now."
            case .openLibrary: "Couldn’t reach Open Library right now."
            }
        }

        func search(_ q: String) async throws -> [SearchResult] {
            switch self {
            case .librivox: try await Catalog.searchAudiobooks(q)
            case .gutenberg: try await Catalog.searchEbooks(q)
            case .openLibrary: try await Catalog.searchScannedBooks(q)
            }
        }
    }

    private struct SourceState {
        var results: [SearchResult] = []
        var loading = false
        var error: String?
    }

    private static let suggestions = ["Sherlock Holmes", "Jane Austen", "Dracula", "Charles Dickens", "Frankenstein", "Mark Twain"]

    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var sources: [CatalogSection: SourceState] = [:]
    @State private var searched = ""
    @State private var tasks: [Task<Void, Never>] = []

    var body: some View {
        Group {
            if searched.isEmpty {
                startPage
            } else {
                results
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Titles or authors")
        .onSubmit(of: .search) { runSearch() }
        .onChange(of: query) { _, new in
            if new.isEmpty { clearSearch() }
        }
    }

    // MARK: - Start page

    private var startPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Free books to listen to")
                        .font(.title2.bold())
                    Text("Everything here is public domain, so think classics. Audiobooks are read by human volunteers; ebooks are read aloud by your phone. It all downloads for offline listening.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Try")
                        .font(.headline)
                    FlowLayout(spacing: 8) {
                        ForEach(Self.suggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                query = suggestion
                                runSearch()
                            }
                            .buttonStyle(.glass)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    sourceRow("headphones", .orange, "LibriVox", "Human-narrated audiobooks")
                    sourceRow("book.closed.fill", .purple, "Project Gutenberg", "Proofread ebooks, read aloud")
                    sourceRow("doc.richtext.fill", .blue, "Open Library", "Original scans as PDFs, read aloud")
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func sourceRow(_ symbol: String, _ tint: Color, _ name: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.tint(tint.opacity(0.15)), in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Results

    private var visibleSections: [CatalogSection] {
        switch filter {
        case .all: CatalogSection.allCases
        case .kind(let kind): CatalogSection.allCases.filter { $0.kind == kind }
        }
    }

    private var results: some View {
        List {
            Picker("Show", selection: $filter) {
                Text("All").tag(Filter.all)
                Text("Audiobooks").tag(Filter.kind(.audiobook))
                Text("Read Aloud").tag(Filter.kind(.tts))
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            ForEach(visibleSections, id: \.self) { section in
                let state = sources[section] ?? SourceState()
                Section {
                    if let error = state.error {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if state.loading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Searching…").foregroundStyle(.secondary)
                        }
                    } else if state.results.isEmpty {
                        Text("No matches for “\(searched)”.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(state.results) { item in
                        ResultRow(item: item, book: library.book(forKey: item.key)) { action in
                            perform(action, on: item)
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.loading || state.error != nil ? section.title : "\(section.title) · \(state.results.count)")
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                        Text(section.note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .textCase(nil)
                    .padding(.bottom, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Actions

    private func clearSearch() {
        tasks.forEach { $0.cancel() }
        tasks = []
        searched = ""
        sources = [:]
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        tasks.forEach { $0.cancel() }
        searched = q
        sources = Dictionary(uniqueKeysWithValues: CatalogSection.allCases.map { ($0, SourceState(loading: true)) })

        tasks = CatalogSection.allCases.map { section in
            Task {
                do {
                    let found = try await section.search(q)
                    guard !Task.isCancelled else { return }
                    withAnimation(.smooth) { sources[section] = SourceState(results: found) }
                } catch {
                    guard !Task.isCancelled else { return }
                    var slow = false
                    if case .timedOut? = error as? Catalog.CatalogError { slow = true }
                    sources[section] = SourceState(error: slow ? "\(section.unreachable) It took too long to respond." : section.unreachable)
                }
            }
        }
    }

    private func perform(_ action: DownloadControl.Action, on item: SearchResult) {
        switch action {
        case .download:
            library.download(item)
        case .cancel:
            if let book = library.book(forKey: item.key) { library.cancel(book.id) }
        case .retry:
            if let book = library.book(forKey: item.key) { library.retry(book.id) }
        case .open:
            if let book = library.book(forKey: item.key) { router.open(book, player: player) }
        }
    }
}

/// One search result: cover, title, author, details and the download control.
private struct ResultRow: View {
    let item: SearchResult
    let book: LibraryBook?
    let onAction: (DownloadControl.Action) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Cover(url: item.coverURL, title: item.title, kind: item.kind, width: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(item.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    KindLabel(kind: item.kind)
                    let meta = [
                        item.source == .openlibrary ? "PDF" : nil,
                        item.runtime,
                        item.year.map(String.init),
                        item.language?.uppercased(),
                    ].compactMap { $0 }
                    if !meta.isEmpty {
                        Text(meta.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DownloadControl(kind: item.kind, book: book, onAction: onAction)
        }
        .padding(.vertical, 4)
    }
}

/// Lays children out left to right, wrapping onto new lines, for the suggestion buttons.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
