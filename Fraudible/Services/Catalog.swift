import Foundation

/// Search across free, legal catalogues:
///  - LibriVox (via the Internet Archive) for human-narrated public-domain audiobooks
///  - Project Gutenberg (via the Gutendex API) for public-domain ebooks read aloud with text-to-speech
nonisolated enum Catalog {
    static let archive = URL(string: "https://archive.org")!
    static let gutendex = URL(string: "https://gutendex.com/books/")!

    nonisolated enum CatalogError: LocalizedError {
        case badStatus(Int)
        case timedOut
        case noMP3s

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): "Request failed (\(code))"
            case .timedOut: "The catalogue took too long to respond"
            case .noMP3s: "No MP3 files found for this audiobook."
            }
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(memoryCapacity: 8_000_000, diskCapacity: 40_000_000)
        return URLSession(configuration: config)
    }()

    static func getData(_ url: URL, accept: String = "application/json") async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw CatalogError.badStatus(http.statusCode)
            }
            return data
        } catch let error as URLError where error.code == .timedOut {
            throw CatalogError.timedOut
        }
    }

    // MARK: - Helpers

    /// Archive.org fields come back as either a string or an array of strings.
    nonisolated struct StringOrArray: Decodable {
        let first: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { first = s }
            else if let a = try? c.decode([String].self) { first = a.first }
            else if let n = try? c.decode(Double.self) { first = String(n) }
            else { first = nil }
        }
    }

    /// Strip characters that have meaning in Lucene query syntax.
    private static func cleanQuery(_ q: String) -> String {
        q.regexReplacing(#"[\\+\-!(){}\[\]^"~*?:/&|]"#, with: " ")
            .regexReplacing(#"\s+"#, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Gutenberg stores names as "Stoker, Bram"; show them as "Bram Stoker".
    private static func displayName(_ name: String) -> String {
        let parts = name.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 && !parts[1].isEmpty ? "\(parts[1]) \(parts[0])" : name
    }

    private static let langCodes: [String: String] = [
        "english": "en", "french": "fr", "german": "de", "spanish": "es", "italian": "it",
        "dutch": "nl", "portuguese": "pt", "russian": "ru", "chinese": "zh", "japanese": "ja",
    ]

    /// Percent-encode a single path component (like JS encodeURIComponent).
    private static func encodeComponent(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - LibriVox audiobooks

    nonisolated struct ArchiveSearchResponse: Decodable {
        nonisolated struct Doc: Decodable {
            let identifier: String
            let title: StringOrArray?
            let creator: StringOrArray?
            let runtime: StringOrArray?
            let language: StringOrArray?
            let downloads: Int?
        }
        nonisolated struct Inner: Decodable { let docs: [Doc] }
        let response: Inner
    }

    static func searchAudiobooks(_ query: String) async throws -> [SearchResult] {
        let q = cleanQuery(query)
        guard !q.isEmpty else { return [] }
        var components = URLComponents(url: archive.appendingPathComponent("advancedsearch.php"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "q", value: "collection:librivoxaudio AND mediatype:audio AND (\(q))")]
        for field in ["identifier", "title", "creator", "runtime", "language", "downloads"] {
            items.append(URLQueryItem(name: "fl[]", value: field))
        }
        items += [
            URLQueryItem(name: "sort[]", value: "downloads desc"),
            URLQueryItem(name: "rows", value: "25"),
            URLQueryItem(name: "output", value: "json"),
        ]
        components.queryItems = items
        // URLComponents leaves "+" alone, which the server would read as a space; that's fine here
        // because cleanQuery already removed every "+".
        let data = try await getData(components.url!)
        let decoded = try JSONDecoder().decode(ArchiveSearchResponse.self, from: data)

        return decoded.response.docs.map { d in
            let lang = d.language?.first?.lowercased()
            let title = (d.title?.first ?? d.identifier).regexReplacing(#"\s*\(LibriVox\)\s*$"#, with: "", options: [.caseInsensitive])
            return SearchResult(
                key: "librivox:\(d.identifier)",
                kind: .audiobook,
                source: .librivox,
                sourceId: d.identifier,
                title: title,
                author: d.creator?.first ?? "Unknown",
                coverURL: URL(string: "https://archive.org/services/img/\(encodeComponent(d.identifier))"),
                language: lang.map { langCodes[$0] ?? String($0.prefix(2)) },
                runtime: d.runtime?.first,
                downloads: d.downloads
            )
        }
    }

    nonisolated struct ArchiveMetadata: Decodable {
        nonisolated struct File: Decodable {
            let name: String
            let format: String?
            let title: String?
            let track: String?
            let length: String?
        }
        let files: [File]?
    }

    private static func parseLength(_ length: String?) -> Double? {
        guard let length, !length.isEmpty else { return nil }
        if length.contains(":") {
            return length.split(separator: ":").reduce(0.0) { acc, part in acc * 60 + (Double(part) ?? 0) }
        }
        return Double(length)
    }

    private static func trackNumber(_ track: String?) -> Int {
        Int((track ?? "").split(separator: "/").first ?? "") ?? Int.max
    }

    /// List the chapter MP3s of a LibriVox item, preferring the smaller 64kbps encodes.
    static func audiobookTracks(identifier: String) async throws -> [Track] {
        let url = archive.appendingPathComponent("metadata").appendingPathComponent(identifier)
        let meta = try JSONDecoder().decode(ArchiveMetadata.self, from: try await getData(url))
        let files = meta.files ?? []
        var mp3s = files.filter { $0.format == "64Kbps MP3" }
        if mp3s.isEmpty { mp3s = files.filter { $0.format == "VBR MP3" || $0.format == "128Kbps MP3" } }
        if mp3s.isEmpty { mp3s = files.filter { $0.name.lowercased().hasSuffix(".mp3") } }
        guard !mp3s.isEmpty else { throw CatalogError.noMP3s }

        mp3s.sort { a, b in
            let ta = trackNumber(a.track), tb = trackNumber(b.track)
            return ta != tb ? ta < tb : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        return mp3s.enumerated().compactMap { i, f in
            let path = f.name.split(separator: "/").map { encodeComponent(String($0)) }.joined(separator: "/")
            guard let url = URL(string: "https://archive.org/download/\(encodeComponent(identifier))/\(path)") else { return nil }
            let title = f.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Track(title: title.isEmpty ? "Chapter \(i + 1)" : title, url: url, duration: parseLength(f.length))
        }
    }

    /// The Internet Archive publishes a .torrent for every item, LibriVox included.
    static func audiobookTorrentURL(identifier: String) -> URL {
        let id = encodeComponent(identifier)
        return URL(string: "https://archive.org/download/\(id)/\(id)_archive.torrent")!
    }

    // MARK: - Gutenberg ebooks (text-to-speech)

    nonisolated struct GutendexResponse: Decodable {
        nonisolated struct Book: Decodable {
            nonisolated struct Author: Decodable { let name: String }
            let id: Int
            let title: String
            let authors: [Author]
            let languages: [String]
            let copyright: Bool?
            let media_type: String
            let formats: [String: String]
            let download_count: Int?
        }
        let results: [Book]
    }

    /// Pick the best format we can turn into plain text.
    static func pickTextFormat(_ formats: [String: String]) -> (url: URL, isHTML: Bool)? {
        let entries = formats.filter { !$0.value.hasSuffix(".zip") }.sorted { $0.key < $1.key }
        let plain = entries.first { $0.key.hasPrefix("text/plain") && $0.key.contains("utf-8") }
            ?? entries.first { $0.key.hasPrefix("text/plain") }
        if let plain, let url = URL(string: plain.value) { return (url, false) }
        if let html = entries.first(where: { $0.key.hasPrefix("text/html") }), let url = URL(string: html.value) {
            return (url, true)
        }
        return nil
    }

    static func searchEbooks(_ query: String) async throws -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var components = URLComponents(url: gutendex, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "search", value: q)]
        let decoded = try JSONDecoder().decode(GutendexResponse.self, from: try await getData(components.url!))

        return decoded.results
            .filter { $0.media_type == "Text" && $0.copyright != true && pickTextFormat($0.formats) != nil }
            .prefix(25)
            .map { b in
                SearchResult(
                    key: "gutenberg:\(b.id)",
                    kind: .tts,
                    source: .gutenberg,
                    sourceId: String(b.id),
                    title: b.title,
                    author: b.authors.isEmpty ? "Unknown" : b.authors.map { displayName($0.name) }.joined(separator: ", "),
                    coverURL: b.formats["image/jpeg"].flatMap(URL.init(string:)),
                    language: b.languages.first,
                    downloads: b.download_count,
                    formats: b.formats
                )
            }
    }
}
