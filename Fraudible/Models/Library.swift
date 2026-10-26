import Foundation
import Observation

/// The user's library: downloaded books, download progress and listening positions.
@Observable
final class Library {
    private(set) var books: [LibraryBook] = []
    private(set) var loaded = false

    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private static var fileURL: URL {
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.v1.json")
    }

    init() {
        load()
    }

    // MARK: - Persistence

    /// Load once at start-up. Anything still "downloading" was interrupted when the app closed.
    private func load() {
        defer { loaded = true }
        guard let data = try? Data(contentsOf: Self.fileURL),
              let saved = try? JSONDecoder().decode([LibraryBook].self, from: data) else {
            // First launch of the Swift app: bring over the old Expo app's library, if there is one.
            if !FileManager.default.fileExists(atPath: Self.fileURL.path), let migrated = ExpoMigration.importOldLibrary() {
                books = migrated
                saveNow()
            }
            return
        }
        books = saved.map { b in
            guard b.status == .downloading else { return b }
            var b = b
            b.status = .error
            b.error = "Download interrupted. Tap to retry."
            return b
        }
    }

    /// Saves are batched: download progress and listening positions change often,
    /// so write at most once a second, always with the latest state.
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.saveTask = nil
            self.saveNow()
        }
    }

    /// Write immediately (also used when the app goes to the background).
    func saveNow() {
        let snapshot = books
        let url = Self.fileURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Queries

    func book(_ id: String) -> LibraryBook? {
        books.first { $0.id == id }
    }

    /// Library entry for a search result, if it has been added.
    func book(forKey key: String) -> LibraryBook? {
        book(Storage.id(fromKey: key))
    }

    // MARK: - Changes

    func update(_ id: String, _ change: (inout LibraryBook) -> Void) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        change(&books[i])
        scheduleSave()
    }

    func download(_ result: SearchResult) {
        let id = Storage.id(fromKey: result.key)
        guard book(id) == nil else { return }
        let book = LibraryBook(
            id: id,
            kind: result.kind,
            source: result.source,
            title: result.title,
            author: result.author,
            coverURL: result.coverURL,
            language: result.language,
            addedAt: .now,
            status: .downloading,
            progress: 0,
            origin: result
        )
        books.insert(book, at: 0)
        scheduleSave()
        run(id, result)
    }

    func retry(_ id: String) {
        guard let origin = book(id)?.origin, downloads[id] == nil else { return }
        update(id) {
            $0.status = .downloading
            $0.progress = 0
            $0.error = nil
        }
        run(id, origin)
    }

    func cancel(_ id: String) {
        downloads[id]?.cancel()
    }

    func remove(_ id: String) {
        downloads[id]?.cancel()
        downloads[id] = nil
        Storage.deleteBookFiles(id)
        books.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Adds a book from text the user imported. Cleaning a long book's text is slow, so it runs off the main thread.
    @discardableResult
    func addImported(title: String, author: String?, text: String) async throws -> LibraryBook {
        let id = "import_\(Int(Date().timeIntervalSince1970 * 1000))"
        let saved = try await Task.detached(priority: .userInitiated) {
            try Storage.saveBookText(bookId: id, text: text)
        }.value
        let book = LibraryBook(
            id: id,
            kind: .tts,
            source: .import,
            title: title,
            author: (author?.isEmpty == false ? author : nil) ?? "Imported",
            addedAt: .now,
            status: .ready,
            progress: 1,
            textFileName: saved.fileName,
            ttsParagraphs: saved.paragraphs
        )
        books.insert(book, at: 0)
        scheduleSave()
        return book
    }

    private func run(_ id: String, _ result: SearchResult) {
        // Only publish whole-percent changes so rows don't re-render on every byte.
        let onProgress: Storage.Progress = { [weak self] fraction in
            Task { @MainActor in
                guard let self else { return }
                let pct = Int(fraction * 100)
                guard let current = self.book(id), Int(current.progress * 100) != pct else { return }
                self.update(id) { $0.progress = fraction }
            }
        }

        downloads[id] = Task { [weak self] in
            defer { self?.downloads[id] = nil }
            do {
                async let cover = Storage.downloadCover(bookId: id, from: result.coverURL)
                switch result.kind {
                case .audiobook:
                    let tracks = try await Storage.downloadAudiobook(bookId: id, result: result, onProgress: onProgress)
                    let coverName = await cover
                    self?.update(id) {
                        $0.status = .ready
                        $0.progress = 1
                        $0.tracks = tracks
                        $0.coverFileName = coverName
                        $0.error = nil
                    }
                case .tts:
                    let saved = try await Storage.downloadEbook(bookId: id, result: result, onProgress: onProgress)
                    let coverName = await cover
                    self?.update(id) {
                        $0.status = .ready
                        $0.progress = 1
                        $0.textFileName = saved.fileName
                        $0.ttsParagraphs = saved.paragraphs
                        $0.coverFileName = coverName
                        $0.error = nil
                    }
                }
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                self?.update(id) {
                    $0.status = .error
                    $0.error = cancelled
                        ? "Download cancelled. Tap to retry."
                        : "\(error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "."))). Tap to retry."
                }
            }
            self?.saveNow()
        }
    }
}

nonisolated extension LibraryBook {
    /// Local cover if one was saved, otherwise the catalogue's remote URL.
    var coverImageURL: URL? {
        if let coverFileName {
            let url = Storage.booksRoot.appendingPathComponent(id).appendingPathComponent(coverFileName)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return coverURL
    }

    func trackFileURL(_ index: Int) -> URL? {
        guard let name = tracks?[safe: index]?.fileName else { return nil }
        return Storage.booksRoot.appendingPathComponent(id).appendingPathComponent(name)
    }
}

nonisolated extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
