import Foundation
import PDFKit
import ZIPFoundation

/// Pulls the text out of a PDF, EPUB or plain-text file the user already owns.
/// Everything runs on the phone with Apple's PDFKit and a small EPUB reader, so no connection is needed.
nonisolated enum Importer {
    nonisolated struct Result: Sendable {
        var text: String
        var title: String?
        var author: String?
    }

    nonisolated enum ImportError: LocalizedError {
        case unreadable, noText, badEPUB
        var errorDescription: String? {
            switch self {
            case .unreadable: "Couldn’t open this file."
            case .noText: "No text was found. Scanned (image-only) PDFs can’t be read aloud."
            case .badEPUB: "This EPUB file looks damaged or uses an unsupported layout."
            }
        }
    }

    static func titleFromFileName(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
            .regexReplacing(#"[_-]+"#, with: " ")
            .trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "Imported book" : base
    }

    /// Extract text from `url`, reporting 0...1 progress. Call off the main thread.
    @concurrent static func extract(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        switch url.pathExtension.lowercased() {
        case "pdf": return try extractPDF(url, progress: progress)
        case "epub": return try extractEPUB(url, progress: progress)
        default:
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
                ?? String(decoding: data, as: UTF8.self)
            progress(1)
            return Result(text: text)
        }
    }

    // MARK: - PDF

    private static func extractPDF(_ url: URL, progress: @Sendable (Double) -> Void) throws -> Result {
        guard let pdf = PDFDocument(url: url) else { throw ImportError.unreadable }
        var pages: [String] = []
        let count = max(pdf.pageCount, 1)
        for i in 0..<pdf.pageCount {
            try Task.checkCancellation()
            if let text = pdf.page(at: i)?.string { pages.append(text) }
            progress(Double(i + 1) / Double(count))
        }
        let text = pages.joined(separator: "\n\n")
        guard text.rangeOfCharacter(from: .letters) != nil else { throw ImportError.noText }
        let attrs = pdf.documentAttributes ?? [:]
        return Result(
            text: text,
            title: (attrs[PDFDocumentAttribute.titleAttribute] as? String)?.trimmed,
            author: (attrs[PDFDocumentAttribute.authorAttribute] as? String)?.trimmed
        )
    }

    // MARK: - EPUB

    private static func extractEPUB(_ url: URL, progress: @Sendable (Double) -> Void) throws -> Result {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) } catch { throw ImportError.unreadable }

        func read(_ path: String) -> Data? {
            guard let entry = archive[path] else { return nil }
            var data = Data()
            _ = try? archive.extract(entry, skipCRC32: true) { data.append($0) }
            return data
        }

        // META-INF/container.xml points at the package (.opf) file.
        guard let containerData = read("META-INF/container.xml"),
              let opfPath = XMLScan(containerData).elements(named: "rootfile").first?["full-path"],
              let opfData = read(opfPath) else { throw ImportError.badEPUB }
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        let opf = XMLScan(opfData)
        let title = opf.text(of: "title")?.trimmed
        let author = opf.text(of: "creator")?.trimmed

        var manifest: [String: String] = [:]
        for item in opf.elements(named: "item") {
            if let id = item["id"], let href = item["href"] { manifest[id] = href }
        }
        let spine = opf.elements(named: "itemref").compactMap { $0["idref"].flatMap { manifest[$0] } }
        guard !spine.isEmpty else { throw ImportError.badEPUB }

        var chapters: [String] = []
        for (i, href) in spine.enumerated() {
            try Task.checkCancellation()
            let clean = href.components(separatedBy: "#")[0].removingPercentEncoding ?? href
            if let data = read(resolve(base: opfDir, href: clean)) {
                let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                chapters.append(TextProcessing.htmlToText(bodyOnly(html)))
            }
            progress(Double(i + 1) / Double(spine.count))
        }
        let text = chapters.joined(separator: "\n\n")
        guard text.rangeOfCharacter(from: .letters) != nil else { throw ImportError.noText }
        return Result(text: text, title: title, author: author)
    }

    /// Chapter files are XHTML; drop everything before <body> so titles in <head> aren't read twice.
    private static func bodyOnly(_ html: String) -> String {
        guard let start = html.regexFirstMatch(#"<body[^>]*>"#, options: [.caseInsensitive]) else { return html }
        return String(html[start.upperBound...])
    }

    private static func resolve(base: String, href: String) -> String {
        var out: [String] = []
        for part in (base.isEmpty ? href : "\(base)/\(href)").split(separator: "/") {
            if part == ".." { _ = out.popLast() } else if part != "." { out.append(String(part)) }
        }
        return out.joined(separator: "/")
    }
}

/// A tiny namespace-agnostic XML reader: enough to find elements, their attributes and text.
nonisolated private final class XMLScan: NSObject, XMLParserDelegate {
    nonisolated struct Element {
        var name: String
        var attributes: [String: String]
        var text = ""
        subscript(key: String) -> String? { attributes[key] }
    }

    private(set) var all: [Element] = []
    private var stack: [Int] = []

    init(_ data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = self
        parser.parse()
    }

    func elements(named name: String) -> [Element] {
        all.filter { $0.name == name }
    }

    func text(of name: String) -> String? {
        elements(named: name).first?.text
    }

    /// "dc:title" → "title"
    private func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        all.append(Element(name: local(elementName), attributes: attributeDict))
        stack.append(all.count - 1)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let i = stack.last { all[i].text += string }
    }
}

nonisolated extension String {
    var trimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
