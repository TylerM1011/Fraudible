import CryptoKit
import Foundation

/// One-time import of the library saved by the old Expo/React Native version of Fraudible.
///
/// Both versions use the bundle id com.tyler.fraudible, so installing this app over the old one
/// keeps its files: downloads already live in Documents/books/<id>/, and the library list sits in
/// React Native AsyncStorage (Application Support/<bundle id>/RCTAsyncLocalStorage_V1).
nonisolated enum ExpoMigration {
    private static let key = "fraudible.library.v1"

    static func importOldLibrary() -> [LibraryBook]? {
        guard let raw = readAsyncStorageValue(key),
              let data = raw.data(using: .utf8),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let books = items.compactMap(convert)
        return books.isEmpty ? nil : books
    }

    private static func readAsyncStorageValue(_ key: String) -> String? {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.tyler.fraudible"
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("RCTAsyncLocalStorage_V1", isDirectory: true)
        guard let manifestData = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let manifest = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any],
              let entry = manifest[key] else { return nil }
        if let inline = entry as? String { return inline }
        // Large values are stored in a separate file named after the MD5 of the key.
        let digest = Insecure.MD5.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return try? String(contentsOf: dir.appendingPathComponent(digest), encoding: .utf8)
    }

    private static func fileName(_ uri: Any?) -> String? {
        guard let uri = uri as? String, !uri.isEmpty else { return nil }
        return URL(string: uri)?.lastPathComponent ?? (uri as NSString).lastPathComponent
    }

    private static func convertResult(_ d: [String: Any]?) -> SearchResult? {
        guard let d,
              let key = d["key"] as? String,
              let kind = (d["kind"] as? String).flatMap(BookKind.init(rawValue:)),
              let source = (d["source"] as? String).flatMap(BookSource.init(rawValue:)),
              let sourceId = d["sourceId"] as? String else { return nil }
        return SearchResult(
            key: key,
            kind: kind,
            source: source,
            sourceId: sourceId,
            title: d["title"] as? String ?? "Untitled",
            author: d["author"] as? String ?? "Unknown",
            coverURL: (d["coverUrl"] as? String).flatMap(URL.init(string:)),
            language: d["language"] as? String,
            runtime: d["runtime"] as? String,
            downloads: d["downloads"] as? Int,
            formats: d["formats"] as? [String: String]
        )
    }

    private static func convert(_ d: [String: Any]) -> LibraryBook? {
        guard let id = d["id"] as? String,
              let kind = (d["kind"] as? String).flatMap(BookKind.init(rawValue:)),
              let source = (d["source"] as? String).flatMap(BookSource.init(rawValue:)) else { return nil }
        let rawStatus = (d["status"] as? String).flatMap(BookStatus.init(rawValue:)) ?? .error
        let status: BookStatus = rawStatus == .downloading ? .error : rawStatus

        var book = LibraryBook(
            id: id,
            kind: kind,
            source: source,
            title: d["title"] as? String ?? "Untitled",
            author: d["author"] as? String ?? "Unknown",
            coverURL: (d["coverUrl"] as? String).flatMap(URL.init(string:)),
            language: d["language"] as? String,
            addedAt: Date(timeIntervalSince1970: (d["addedAt"] as? Double ?? Date().timeIntervalSince1970 * 1000) / 1000),
            status: status,
            progress: d["progress"] as? Double ?? 0,
            error: status == .error ? (d["error"] as? String ?? "Download interrupted. Tap to retry.") : nil,
            origin: convertResult(d["origin"] as? [String: Any])
        )

        if let tracks = d["tracks"] as? [[String: Any]] {
            book.tracks = tracks.compactMap { t in
                guard let url = (t["url"] as? String).flatMap(URL.init(string:)) else { return nil }
                return Track(title: t["title"] as? String ?? "Chapter", url: url, fileName: fileName(t["file"]), duration: t["duration"] as? Double)
            }
        }
        if let pos = d["audioPosition"] as? [String: Any], let track = pos["track"] as? Int {
            book.audioPosition = AudioPosition(track: track, seconds: pos["seconds"] as? Double ?? 0)
        }
        book.textFileName = fileName(d["textFile"])
        book.ttsPosition = d["ttsPosition"] as? Int
        // The old app split text into longer chunks, so its chunk index doesn't apply; resume at the paragraph.
        book.ttsChunkPosition = nil
        book.ttsParagraphs = d["ttsChunks"] as? Int
        book.ttsRate = d["ttsRate"] as? Double
        if let voice = d["ttsVoice"] as? String { book.ttsVoice = "kokoro:\(voice)" }
        return book
    }
}
