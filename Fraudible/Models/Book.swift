import Foundation

/// How a book is listened to.
nonisolated enum BookKind: String, Codable, Hashable, CaseIterable, Sendable {
    case audiobook
    case tts

    var label: String {
        switch self {
        case .audiobook: "Audiobook"
        case .tts: "Text-to-speech"
        }
    }
}

/// Where a book came from.
nonisolated enum BookSource: String, Codable, Hashable, Sendable {
    case librivox
    case gutenberg
    case `import`
}

/// A single row in the search results.
nonisolated struct SearchResult: Codable, Hashable, Identifiable, Sendable {
    /// Unique across sources, e.g. "librivox:dracula_librivox".
    var key: String
    var kind: BookKind
    var source: BookSource
    /// Internet Archive identifier (LibriVox) or Gutenberg book id.
    var sourceId: String
    var title: String
    var author: String
    var coverURL: URL?
    /// ISO 639-1 code where known, e.g. "en".
    var language: String?
    /// Human-readable runtime for audiobooks, e.g. "15:31:02".
    var runtime: String?
    var downloads: Int?
    /// Gutenberg only: the URLs of the formats on offer, keyed by MIME type.
    var formats: [String: String]?

    var id: String { key }
}

/// One chapter/file of a downloaded audiobook.
nonisolated struct Track: Codable, Hashable, Sendable {
    var title: String
    /// Remote URL it was downloaded from.
    var url: URL
    /// File name inside the book's folder once downloaded (e.g. "001.mp3").
    var fileName: String?
    /// Seconds, if the catalogue reported it.
    var duration: Double?
}

nonisolated enum BookStatus: String, Codable, Hashable, Sendable {
    case downloading
    case ready
    case error
}

nonisolated struct AudioPosition: Codable, Hashable, Sendable {
    var track: Int
    var seconds: Double
}

nonisolated struct LibraryBook: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var kind: BookKind
    var source: BookSource
    var title: String
    var author: String
    var coverURL: URL?
    /// Cover image saved next to the book's files, so it shows offline.
    var coverFileName: String?
    var language: String?
    var addedAt: Date
    var status: BookStatus
    /// 0...1 while downloading.
    var progress: Double
    var error: String?
    /// The search result this book was created from, kept so a failed download can be retried.
    var origin: SearchResult?

    // Audiobooks
    var tracks: [Track]?
    var audioPosition: AudioPosition?

    // Text-to-speech books
    /// File name of the cleaned plain text inside the book's folder.
    var textFileName: String?
    /// Index of the paragraph the reader was on.
    var ttsPosition: Int?
    /// Index of the exact chunk the reader last played, so a long paragraph resumes
    /// where it stopped instead of restarting from its first sentence.
    var ttsChunkPosition: Int?
    /// Total paragraph count, for showing progress in the library.
    var ttsParagraphs: Int?
    var ttsRate: Double?
    var ttsVoice: String?

    var isReady: Bool { status == .ready }
}
