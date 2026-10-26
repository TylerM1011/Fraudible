import SwiftUI
import UniformTypeIdentifiers

/// Downloaded books, download progress, and importing your own PDF/EPUB/TXT files.
struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(AudiobookPlayer.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(\.palette) private var c

    @State private var showImporter = false
    @State private var importing = false
    @State private var importProgress = 0.0
    @State private var importTask: Task<Void, Never>?
    @State private var alert: String?
    @State private var pendingDelete: LibraryBook?

    private var sorted: [LibraryBook] {
        library.books.sorted { $0.addedAt > $1.addedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if importing { importCard }
            List {
                if library.loaded && library.books.isEmpty {
                    emptyState.listRowBackground(c.bg).listRowSeparator(.hidden)
                }
                ForEach(sorted) { book in
                    Button { tap(book) } label: { LibraryRow(book: book) }
                        .buttonStyle(.plain)
                        .listRowBackground(c.bg)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .contextMenu { menu(for: book) }
                        .swipeActions {
                            Button("Delete", role: .destructive) { pendingDelete = book }
                        }
                }
                if !library.books.isEmpty {
                    Text("Swipe or long-press a book to delete it.")
                        .font(.mono(11, weight: .regular))
                        .foregroundStyle(c.faint)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(c.bg)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(c.bg)
        .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayer() }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Library").font(.mono(18, weight: .heavy)).foregroundStyle(c.text)
            }
            ToolbarItem(placement: .topBarTrailing) { ThemeToggle() }
        }
        .retroNavigation(c)
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
            Button("Delete from device", role: .destructive) {
                if let book = pendingDelete { delete(book) }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("This removes the downloaded files from your phone.")
        }
    }

    private var header: some View {
        HStack {
            Text("\(library.books.count) \(library.books.count == 1 ? "book" : "books") on this device")
                .font(.system(size: 13))
                .foregroundStyle(c.muted)
            Spacer()
            Button("+ Import PDF / EPUB") { showImporter = true }
                .buttonStyle(RetroButtonStyle(variant: .ghost, small: true))
                .disabled(importing)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var importCard: some View {
        HStack(spacing: 12) {
            ProgressView().tint(c.tts)
            VStack(alignment: .leading, spacing: 6) {
                Text("Extracting text… \(Int(importProgress * 100))%").font(.system(size: 12)).foregroundStyle(c.faint)
                ProgressBar(value: importProgress, color: c.tts)
            }
            Button("Cancel") { importTask?.cancel() }
                .buttonStyle(RetroButtonStyle(variant: .ghost, small: true))
        }
        .padding(12)
        .background(c.surface)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(c.border, lineWidth: 2))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing here yet").font(.mono(22, weight: .heavy)).foregroundStyle(c.text)
            Text("Download a book from Search, or import a PDF, EPUB or text file you own to have it read aloud.")
                .font(.system(size: 15))
                .foregroundStyle(c.muted)
                .lineSpacing(4)
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func menu(for book: LibraryBook) -> some View {
        if book.status == .downloading {
            Button("Cancel download") { library.cancel(book.id) }
        }
        if let pdf = book.pdfFileURL {
            ShareLink(item: pdf) { Label("Share PDF", systemImage: "square.and.arrow.up") }
        }
        Button("Delete from device", role: .destructive) { pendingDelete = book }
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

/// One book in the library, with its download or listening progress.
private struct LibraryRow: View {
    let book: LibraryBook
    @Environment(\.palette) private var c

    var body: some View {
        HStack(spacing: 12) {
            Cover(url: book.coverImageURL, title: book.title, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                KindBadge(kind: book.kind)
                Text(book.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(c.text)
                    .lineLimit(2)
                Text(book.author)
                    .font(.system(size: 13))
                    .foregroundStyle(c.muted)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(book.status == .error ? c.danger : c.faint)
                    .lineLimit(2)
                if book.status == .downloading {
                    ProgressBar(value: book.progress, color: c.kind(book.kind))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private var statusLine: String {
        switch book.status {
        case .downloading: return "Downloading… \(Int(book.progress * 100))%"
        case .error: return book.error ?? "Download failed. Tap to retry."
        case .ready: break
        }
        if book.kind == .audiobook {
            let count = book.tracks?.count ?? 0
            var line = "\(count) chapters"
            if let pos = book.audioPosition, pos.track > 0 || pos.seconds > 5 {
                line += " · Chapter \(pos.track + 1), \(formatTime(pos.seconds))"
            }
            return line
        }
        let total = book.ttsParagraphs ?? 0
        let at = book.ttsPosition ?? 0
        let read = total > 0 ? "\(Int(Double(at) / Double(total) * 100))% read" : "Ready"
        return book.pdfFileName != nil ? "\(read) · PDF saved" : read
    }
}
