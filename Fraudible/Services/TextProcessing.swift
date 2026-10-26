import Foundation

/// Text clean-up and chunking for text-to-speech.
nonisolated enum TextProcessing {
    /// Max characters per spoken chunk. Kokoro accepts at most 510 phoneme tokens per call,
    /// and shorter chunks make pausing, skipping and speed changes feel snappier.
    static let maxChunk = 320

    /// Remove the Project Gutenberg licence header and footer, keeping only the book itself.
    static func stripGutenbergBoilerplate(_ text: String) -> String {
        var body = text
        if let start = body.regexFirstMatch(#"\*{3}\s*START OF (THE|THIS) PROJECT GUTENBERG E-?BOOK[^*]*\*{3}"#, options: [.caseInsensitive]) {
            body = String(body[start.upperBound...])
        }
        if let end = body.regexFirstMatch(#"\*{3}\s*END OF (THE|THIS) PROJECT GUTENBERG E-?BOOK"#, options: [.caseInsensitive]) {
            body = String(body[..<end.lowerBound])
        }
        return body
    }

    /// Very small HTML-to-text converter, used for Gutenberg HTML editions and EPUB chapters.
    static func htmlToText(_ html: String) -> String {
        var s = html
        s = s.regexReplacing(#"<(script|style|head)[\s\S]*?</\1>"#, with: "", options: [.caseInsensitive])
        s = s.regexReplacing(#"<br\s*/?>"#, with: "\n", options: [.caseInsensitive])
        s = s.regexReplacing(#"</(p|div|h[1-6]|li|blockquote|tr|section|article)>"#, with: "\n\n", options: [.caseInsensitive])
        s = s.regexReplacing(#"<[^>]+>"#, with: "")
        return decodeEntities(s)
    }

    static func decodeEntities(_ text: String) -> String {
        var s = text
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
            ("&rdquo;", "”"), ("&ldquo;", "“"), ("&mdash;", "—"), ("&ndash;", "–"),
            ("&hellip;", "…"), ("&eacute;", "é"), ("&egrave;", "è"), ("&aelig;", "æ"),
        ]
        for (entity, value) in named { s = s.replacingOccurrences(of: entity, with: value) }
        s = s.regexReplacingMatches(#"&#(x?[0-9a-fA-F]+);"#) { groups in
            let raw = groups[1]
            let value = raw.hasPrefix("x") || raw.hasPrefix("X")
                ? UInt32(raw.dropFirst(), radix: 16)
                : UInt32(raw, radix: 10)
            guard let value, let scalar = Unicode.Scalar(value) else { return "" }
            return String(Character(scalar))
        }
        // &amp; last, so "&amp;lt;" becomes "&lt;" rather than "<".
        return s.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Kokoro's phonemiser can choke on very long digit runs, which PDF extraction often produces
    /// by losing the spaces between page numbers or table cells, so break them up.
    private static func breakLongDigitRuns(_ text: String) -> String {
        text.regexReplacingMatches(#"\d{7,}"#) { groups in
            groups[0].regexReplacing(#"(\d{3})(?=\d)"#, with: "$1 ")
        }
    }

    /// Turn raw text into clean paragraphs: hard-wrapped lines are joined,
    /// blank lines separate paragraphs, decorative lines are dropped.
    static func toParagraphs(_ text: String) -> [String] {
        let normalised = text.regexReplacing(#"\r\n?"#, with: "\n")
        return normalised
            .regexSplit( #"\n[ \t]*\n+"#)
            .map { p in
                p.regexReplacing(#"-\n(?=[a-z])"#, with: "") // re-join words hyphenated across lines
                    .regexReplacing(#"\s*\n\s*"#, with: " ")
                    .replacingOccurrences(of: "_", with: "") // Gutenberg marks italics with underscores
                    .regexReplacing(#"\s+"#, with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .map(breakLongDigitRuns)
            // Drop separator lines such as "* * *" that contain no letters or digits.
            .filter { $0.rangeOfCharacter(from: .alphanumerics) != nil }
    }

    private static func splitSentences(_ paragraph: String) -> [String] {
        let parts = paragraph.regexMatches(#"[^.!?…]+(?:[.!?…]+["'”’)\]]*|$)\s*"#)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [paragraph] : parts
    }

    private static func hardSplit(_ sentence: String, max: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for word in sentence.split(separator: " ") {
            if !current.isEmpty && current.count + word.count + 1 > max {
                out.append(current)
                current = String(word)
            } else {
                current = current.isEmpty ? String(word) : "\(current) \(word)"
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Split paragraphs into speakable chunks of at most `max` characters, tagging each with its
    /// source paragraph so playback and skipping stay at paragraph granularity.
    /// Deterministic, so a saved chunk index always points at the same place.
    static func chunk(_ paragraphs: [String], max: Int = maxChunk) -> [Chunk] {
        var chunks: [Chunk] = []
        for (index, p) in paragraphs.enumerated() {
            if p.count <= max {
                chunks.append(Chunk(text: p, paragraph: index))
                continue
            }
            var current = ""
            for sentence in splitSentences(p) {
                let pieces = sentence.count > max ? hardSplit(sentence, max: max) : [sentence]
                for piece in pieces {
                    if !current.isEmpty && current.count + piece.count + 1 > max {
                        chunks.append(Chunk(text: current, paragraph: index))
                        current = piece
                    } else {
                        current = current.isEmpty ? piece : "\(current) \(piece)"
                    }
                }
            }
            if !current.isEmpty { chunks.append(Chunk(text: current, paragraph: index)) }
        }
        return chunks
    }
}

/// A speakable unit for the TTS engine, tagged with the paragraph it was split from.
nonisolated struct Chunk: Hashable, Sendable {
    var text: String
    /// Index into the paragraph array. Several chunks can share one paragraph.
    var paragraph: Int
}

// MARK: - Small regex helpers (NSRegularExpression, so behaviour matches the JS original)

nonisolated extension String {
    private func regex(_ pattern: String, _ options: NSRegularExpression.Options) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: options)
    }

    private var fullRange: NSRange { NSRange(startIndex..., in: self) }

    func regexReplacing(_ pattern: String, with template: String, options: NSRegularExpression.Options = []) -> String {
        guard let re = regex(pattern, options) else { return self }
        return re.stringByReplacingMatches(in: self, range: fullRange, withTemplate: template)
    }

    /// Replace each match with the closure's result. `groups[0]` is the whole match.
    func regexReplacingMatches(_ pattern: String, options: NSRegularExpression.Options = [], _ transform: ([String]) -> String) -> String {
        guard let re = regex(pattern, options) else { return self }
        var result = ""
        var last = startIndex
        for match in re.matches(in: self, range: fullRange) {
            guard let range = Range(match.range, in: self) else { continue }
            result += self[last..<range.lowerBound]
            var groups: [String] = []
            for i in 0..<match.numberOfRanges {
                if let r = Range(match.range(at: i), in: self) { groups.append(String(self[r])) } else { groups.append("") }
            }
            result += transform(groups)
            last = range.upperBound
        }
        result += self[last...]
        return result
    }

    func regexFirstMatch(_ pattern: String, options: NSRegularExpression.Options = []) -> Range<String.Index>? {
        guard let re = regex(pattern, options), let m = re.firstMatch(in: self, range: fullRange) else { return nil }
        return Range(m.range, in: self)
    }

    func regexMatches(_ pattern: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let re = regex(pattern, options) else { return [] }
        return re.matches(in: self, range: fullRange).compactMap { Range($0.range, in: self).map { String(self[$0]) } }
    }

    func regexSplit(_ pattern: String) -> [String] {
        guard let re = regex(pattern, []) else { return [self] }
        var parts: [String] = []
        var last = startIndex
        for match in re.matches(in: self, range: fullRange) {
            guard let range = Range(match.range, in: self) else { continue }
            parts.append(String(self[last..<range.lowerBound]))
            last = range.upperBound
        }
        parts.append(String(self[last...]))
        return parts
    }
}
