import SwiftUI
import UniformTypeIdentifiers

/// Downloaded books, download progress, and importing your own PDF/EPUB/TXT files.
struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(AudiobookPlayer.self) private var player
    @Environment(AppRouter.self) private var router

    @State private var showImporter = false
    @State private var importing = false
    @State private var importProgress = 0.0
    @State private var importTask: Task<Void, Never>?
    @State private var alert: String?
    @State private var pendingDelete: LibraryBook?

    private var sorted: [LibraryBook] {
        library.books.sorted { $0.addedAt > $1.addedAt }
    }

    /// The most recently started book that isn't finished, for the "Continue" card.
    private var continueBook: LibraryBook? {
        sorted.first { book in
            guard book.isReady else { return false }
            if book.kind == .audiobook {
                guard let pos = book.audioPosition else { return false }
                return pos.track > 0 || pos.seconds > 5
            }
            return (book.ttsPosition ?? 0) > 0
        }
    }

    var body: some View {
        Group {
            if library.loaded && library.books.isEmpty && !importing {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImporter = true } label: {
                    Label("Import a PDF, EPUB or text file", systemImage: "plus")
                }
                .disabled(importing)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .epub, .plainText]) { result in
            if case .success(let url) = result { startImport(url) }
        }
        .alert("Import failed", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
        .confirmationDialog(
            pendingDelete?.title ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete from iPhone", role: .destructive) {
                if let book = pendingDelete { delete(book) }
            }
        } message: {
            Text("This removes the downloaded files. You can download the book again later.")
        }
    }

    // MARK: - Pieces

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Books Yet", systemImage: "books.vertical")
        } description: {
            Text("Find free audiobooks and ebooks in Search, or import a PDF, EPUB or text file you own to have it read aloud.")
        } actions: {
            Button("Find Books") { router.tab = .search }
                .buttonStyle(.glassProminent)
            Button("Import a File") { showImporter = true }
                .buttonStyle(.glass)
        }
    }

    private var list: some View {
        List {
            if let book = continueBook {
                Section {
                    ContinueCard(book: book) { tap(book) }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } header: {
                    Text("Continue")
                }
            }

            if importing {
                Section {
                    HStack(spacing: 14) {
                        ProgressRing(value: importProgress, tint: .purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Importing…").font(.subheadline.weight(.semibold))
                            Text("Extracting text · \(Int(importProgress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") { importTask?.cancel() }
                            .buttonStyle(.glass)
                    }
                }
            }

            Section {
                ForEach(sorted) { book in
                    Button { tap(book) } label: { LibraryRow(book: book) }
                        .buttonStyle(.plain)
                        .contextMenu { menu(for: book) }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = book }
                        }
                }
            } header: {
                Text("\(library.books.count) \(library.books.count == 1 ? "Book" : "Books")")
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func menu(for book: LibraryBook) -> some View {
        if book.status == .downloading {
            Button("Cancel Download", systemImage: "xmark.circle") { library.cancel(book.id) }
        }
        if let pdf = book.pdfFileURL {
            ShareLink(item: pdf) { Label("Share PDF", systemImage: "square.and.arrow.up") }
        }
        Button("Delete from iPhone", systemImage: "trash", role: .destructive) { pendingDelete = book }
    }

    // MARK: - Actions

    private func tap(_ book: LibraryBook) {
        switch book.status {
        case .error: library.retry(book.id)
        case .ready: router.open(book, player: player)
        case .downloading: break
        }
    }

    private func delete(_ book: LibraryBook) {
        player.unload(book.id)
        library.remove(book.id)
    }

    private func startImport(_ picked: URL) {
        importing = true
        importProgress = 0
        importTask = Task {
            defer {
                importing = false
                importTask = nil
            }
            do {
                // Copy out of the Files app's sandbox first; the original stays untouched.
                let local = try copyToTemporary(picked)
                defer { try? FileManager.default.removeItem(at: local) }
                let result = try await Importer.extract(from: local) { p in
                    Task { @MainActor in importProgress = p }
                }
                try Task.checkCancellation()
                let book = try await library.addImported(
                    title: result.title ?? Importer.titleFromFileName(picked.lastPathComponent),
                    author: result.author,
                    text: result.text
                )
                router.openReader(book.id)
            } catch is CancellationError {
                // The user cancelled.
            } catch {
                alert = error.localizedDescription
            }
        }
    }

    private func copyToTemporary(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }
}

/// Big card for the book you were last listening to, on a glass panel tinted by its kind.
private struct ContinueCard: View {
    let book: LibraryBook
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Cover(url: book.coverImageURL, title: book.title, kind: book.kind, width: 64)
                VStack(alignment: .leading, spacing: 4) {
                    KindLabel(kind: book.kind)
                    Text(book.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(book.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(LibraryRow.whereYouAre(book))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
            }
            .padding(16)
            .glassEffect(.regular.tint(book.kind.tint.opacity(0.12)).interactive(), in: .rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Continue \(book.title)")
    }
}

/// One book in the library, with its download or listening progress.
private struct LibraryRow: View {
    let book: LibraryBook
    @Environment(OfflineAudioMaker.self) private var maker

    var body: some View {
        HStack(spacing: 14) {
            Cover(url: book.coverImageURL, title: book.title, kind: book.kind, width: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(book.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    KindLabel(kind: book.kind)
                    Text(statusLine)
                        .font(.caption2)
                        .foregroundStyle(book.status == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                }
                if let progress {
                    ProgressView(value: progress)
                        .tint(book.status == .downloading ? book.kind.tint : .accentColor)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if book.status == .error {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Tap to retry")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Download progress, or how far through the book you are.
    private var progress: Double? {
        if book.status == .downloading { return book.progress }
        guard book.isReady, book.kind == .tts, let total = book.ttsParagraphs, total > 0, let at = book.ttsPosition, at > 0 else { return nil }
        return Double(at + 1) / Double(total)
    }

    private var statusLine: String {
        switch book.status {
        case .downloading: return "Downloading \(Int(book.progress * 100))%"
        case .error: return book.error ?? "Download failed. Tap to retry."
        case .ready:
            let place = Self.whereYouAre(book)
            return maker.badge(book.id).map { "\(place) · \($0)" } ?? place
        }
    }

    static func whereYouAre(_ book: LibraryBook) -> String {
        if book.kind == .audiobook {
            let count = book.tracks?.count ?? 0
            if let pos = book.audioPosition, pos.track > 0 || pos.seconds > 5 {
                return "Chapter \(pos.track + 1) of \(count) · \(formatTime(pos.seconds))"
            }
            return "\(count) chapters"
        }
        let total = book.ttsParagraphs ?? 0
        let at = book.ttsPosition ?? 0
        let read = total > 0 && at > 0 ? "\(Int(Double(at + 1) / Double(total) * 100))% read" : "Not started"
        return book.pdfFileName != nil ? "\(read) · PDF" : read
    }
}
