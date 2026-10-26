import Foundation

/// On-device storage: downloaded files live under <Documents>/books/<bookId>/.
/// The library stores file *names* only, because the app container's absolute path
/// can change between installs and updates.
nonisolated enum Storage {
    static var booksRoot: URL {
        let dir = URL.documentsDirectory.appendingPathComponent("books", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func bookDir(_ bookId: String) -> URL {
        let dir = booksRoot.appendingPathComponent(bookId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(bookId: String, name: String) -> URL {
        bookDir(bookId).appendingPathComponent(name)
    }

    static func deleteBookFiles(_ bookId: String) {
        try? FileManager.default.removeItem(at: booksRoot.appendingPathComponent(bookId, isDirectory: true))
    }

    /// File-system-safe id from a search key such as "librivox:dracula_librivox".
    static func id(fromKey key: String) -> String {
        key.regexReplacing(#"[^a-zA-Z0-9_-]+"#, with: "_")
    }

    typealias Progress = @Sendable (Double) -> Void

    /// Download every chapter MP3 of a LibriVox audiobook, one after another.
    static func downloadAudiobook(bookId: String, result: SearchResult, onProgress: @escaping Progress) async throws -> [Track] {
        let tracks = try await Catalog.audiobookTracks(identifier: result.sourceId)
        let dir = bookDir(bookId)
        var done: [Track] = []

        for (i, track) in tracks.enumerated() {
            try Task.checkCancellation()
            let name = String(format: "%03d.mp3", i + 1)
            let target = dir.appendingPathComponent(name)
            let existing = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if existing == 0 {
                let count = Double(tracks.count)
                try await Downloader.download(track.url, to: target) { part in
                    onProgress((Double(i) + part) / count)
                }
            }
            var saved = track
            saved.fileName = name
            done.append(saved)
            onProgress(Double(i + 1) / Double(tracks.count))
        }
        return done
    }

    /// Save already-extracted text as a book; returns the file name and paragraph count.
    static func saveBookText(bookId: String, text: String) throws -> (fileName: String, paragraphs: Int) {
        let paragraphs = TextProcessing.toParagraphs(text)
        guard !paragraphs.isEmpty else { throw StorageError.noText }
        let name = "book.txt"
        try paragraphs.joined(separator: "\n\n").write(to: fileURL(bookId: bookId, name: name), atomically: true, encoding: .utf8)
        return (name, paragraphs.count)
    }

    /// Download a Gutenberg ebook as plain text, ready for text-to-speech.
    @concurrent static func downloadEbook(bookId: String, result: SearchResult, onProgress: @escaping Progress) async throws -> (fileName: String, paragraphs: Int) {
        guard let format = Catalog.pickTextFormat(result.formats ?? [:]) else { throw StorageError.noPlainText }
        onProgress(0.1)
        let data = try await Catalog.getData(format.url, accept: "*/*")
        try Task.checkCancellation()
        onProgress(0.7)
        var text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if format.isHTML { text = TextProcessing.htmlToText(text) }
        text = TextProcessing.stripGutenbergBoilerplate(text)
        let saved = try saveBookText(bookId: bookId, text: text)
        onProgress(1)
        return saved
    }

    /// Save a cover image next to the book so it shows offline. Best-effort.
    static func downloadCover(bookId: String, from url: URL?) async -> String? {
        guard let url else { return nil }
        guard let data = try? await Catalog.getData(url, accept: "image/*"), data.count > 512 else { return nil }
        let name = "cover.jpg"
        do {
            try data.write(to: fileURL(bookId: bookId, name: name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    /// Load the stored paragraphs of a text-to-speech book.
    static func loadParagraphs(bookId: String, fileName: String) throws -> [String] {
        let text = try String(contentsOf: fileURL(bookId: bookId, name: fileName), encoding: .utf8)
        return text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
    }

    nonisolated enum StorageError: LocalizedError {
        case noText, noPlainText
        var errorDescription: String? {
            switch self {
            case .noText: "No readable text was found in this book."
            case .noPlainText: "This ebook has no plain-text edition."
            }
        }
    }
}

/// A file download with progress reporting and cancellation.
nonisolated enum Downloader {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 2
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    nonisolated private final class Box: @unchecked Sendable {
        var task: URLSessionDownloadTask?
        var observation: NSKeyValueObservation?
        let lock = NSLock()
        var cancelled = false
    }

    /// Downloads `url` to `destination` (replacing anything there), reporting 0...1 progress.
    static func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let box = Box()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: url) { tempURL, response, error in
                    box.observation?.invalidate()
                    if let error {
                        continuation.resume(throwing: box.cancelled ? CancellationError() : error)
                        return
                    }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        continuation.resume(throwing: Catalog.CatalogError.badStatus(http.statusCode))
                        return
                    }
                    guard let tempURL else {
                        continuation.resume(throwing: URLError(.cannotCreateFile))
                        return
                    }
                    do {
                        let fm = FileManager.default
                        try? fm.removeItem(at: destination)
                        try fm.moveItem(at: tempURL, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.observation = task.progress.observe(\.fractionCompleted) { p, _ in
                    progress(p.fractionCompleted)
                }
                box.lock.lock()
                box.task = task
                let alreadyCancelled = box.cancelled
                box.lock.unlock()
                if alreadyCancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            box.lock.lock()
            box.cancelled = true
            let task = box.task
            box.lock.unlock()
            task?.cancel()
        }
    }
}
