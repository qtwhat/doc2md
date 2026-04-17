import Foundation

enum EpubConverterError: LocalizedError {
    case invalidEpub(String)
    case missingOpf
    case noSpine

    var errorDescription: String? {
        switch self {
        case .invalidEpub(let msg): return "EPUB 格式错误: \(msg)"
        case .missingOpf: return "EPUB 缺少 OPF 文件"
        case .noSpine: return "EPUB 没有可读章节"
        }
    }
}

struct EpubChapter {
    let id: String
    let href: String
    let title: String?
    let markdown: String
}

struct EpubConversionResult {
    let bookTitle: String
    let authors: [String]
    let language: String?
    let chapters: [EpubChapter]

    /// Aggregate to a single Markdown string with chapter separators.
    func combinedMarkdown() -> String {
        var md = ""
        // Frontmatter-style header
        md += "# \(bookTitle)\n\n"
        if !authors.isEmpty {
            md += "**作者：** \(authors.joined(separator: ", "))\n\n"
        }
        if let lang = language, !lang.isEmpty {
            md += "**语言：** \(lang)\n\n"
        }
        md += "---\n\n"
        for (i, chapter) in chapters.enumerated() {
            if i > 0 { md += "\n---\n\n" }
            if let t = chapter.title, !t.isEmpty {
                md += "## \(t)\n\n"
            }
            md += chapter.markdown
            if !chapter.markdown.hasSuffix("\n") { md += "\n" }
        }
        return md
    }
}

struct EpubConverter {

    /// Convenience: returns a combined single-file Markdown (for the generic
    /// `convert(url:)` entry point used by callers that don't need per-chapter
    /// splitting).
    func convert(url: URL) throws -> String {
        let result = try parse(url: url)
        return result.combinedMarkdown()
    }

    /// Parse EPUB into structured result (for per-chapter output mode).
    func parse(url: URL) throws -> EpubConversionResult {
        let tempDir = try ZipExtractor.extract(url: url)
        defer { ZipExtractor.cleanup(tempDir: tempDir) }

        // Locate OPF via META-INF/container.xml
        let containerURL = tempDir.appendingPathComponent("META-INF/container.xml")
        guard let containerDoc = try? XMLDocument(contentsOf: containerURL, options: [.nodePreserveAll]) else {
            throw EpubConverterError.invalidEpub("container.xml 不可读")
        }
        guard let opfPath = findOpfPath(container: containerDoc) else {
            throw EpubConverterError.missingOpf
        }

        let opfURL = tempDir.appendingPathComponent(opfPath)
        let opfBaseDir = opfURL.deletingLastPathComponent()

        guard let opfDoc = try? XMLDocument(contentsOf: opfURL, options: [.nodePreserveAll]),
              let opfRoot = opfDoc.rootElement() else {
            throw EpubConverterError.invalidEpub("OPF 不可读")
        }

        let metadata = parseMetadata(opfRoot: opfRoot)
        let manifest = parseManifest(opfRoot: opfRoot)  // id → (href, mediaType)
        let spine = parseSpine(opfRoot: opfRoot)        // [idref]

        guard !spine.isEmpty else { throw EpubConverterError.noSpine }

        // Convert each chapter
        var chapters: [EpubChapter] = []
        for idref in spine {
            guard let item = manifest[idref] else { continue }
            let mediaType = item.mediaType.lowercased()
            // Only convert HTML/XHTML
            guard mediaType.contains("html") else { continue }

            let chapterURL = opfBaseDir.appendingPathComponent(item.href)
            guard let data = try? Data(contentsOf: chapterURL) else { continue }

            // Extract chapter title (first h1/h2/h3 in markdown OR from HTML <title>)
            let title = extractChapterTitle(data: data)
            guard let md = try? XHtmlToMarkdown.convert(data: data) else { continue }

            let trimmed = md.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            chapters.append(EpubChapter(
                id: idref,
                href: item.href,
                title: title,
                markdown: md
            ))
        }

        guard !chapters.isEmpty else {
            throw EpubConverterError.noSpine
        }

        return EpubConversionResult(
            bookTitle: metadata.title ?? url.deletingPathExtension().lastPathComponent,
            authors: metadata.authors,
            language: metadata.language,
            chapters: chapters
        )
    }

    // MARK: - Parse helpers

    private func findOpfPath(container: XMLDocument) -> String? {
        guard let root = container.rootElement() else { return nil }
        // container.xml structure: <container><rootfiles><rootfile full-path="..." ...>
        for child in root.children ?? [] {
            guard let el = child as? XMLElement,
                  (el.localName ?? el.name ?? "") == "rootfiles" else { continue }
            for rf in el.children ?? [] {
                guard let rEl = rf as? XMLElement,
                      (rEl.localName ?? rEl.name ?? "") == "rootfile",
                      let fp = rEl.attribute(forName: "full-path")?.stringValue else { continue }
                return fp
            }
        }
        return nil
    }

    private struct Metadata {
        var title: String?
        var authors: [String] = []
        var language: String?
    }

    private func parseMetadata(opfRoot: XMLElement) -> Metadata {
        var meta = Metadata()
        guard let metadataEl = firstChild(opfRoot, localName: "metadata") else { return meta }
        for child in metadataEl.children ?? [] {
            guard let el = child as? XMLElement else { continue }
            let name = el.localName ?? el.name ?? ""
            switch name {
            case "title":
                if meta.title == nil { meta.title = el.stringValue }
            case "creator":
                if let s = el.stringValue, !s.isEmpty { meta.authors.append(s) }
            case "language":
                if meta.language == nil { meta.language = el.stringValue }
            default: break
            }
        }
        return meta
    }

    private struct ManifestItem {
        let href: String
        let mediaType: String
    }

    private func parseManifest(opfRoot: XMLElement) -> [String: ManifestItem] {
        var result: [String: ManifestItem] = [:]
        guard let manifestEl = firstChild(opfRoot, localName: "manifest") else { return result }
        for child in manifestEl.children ?? [] {
            guard let el = child as? XMLElement,
                  (el.localName ?? el.name ?? "") == "item",
                  let id = el.attribute(forName: "id")?.stringValue,
                  let href = el.attribute(forName: "href")?.stringValue else { continue }
            let mt = el.attribute(forName: "media-type")?.stringValue ?? ""
            result[id] = ManifestItem(href: href, mediaType: mt)
        }
        return result
    }

    private func parseSpine(opfRoot: XMLElement) -> [String] {
        var result: [String] = []
        guard let spineEl = firstChild(opfRoot, localName: "spine") else { return result }
        for child in spineEl.children ?? [] {
            guard let el = child as? XMLElement,
                  (el.localName ?? el.name ?? "") == "itemref" else { continue }
            // Skip linear="no" items
            let linear = el.attribute(forName: "linear")?.stringValue ?? "yes"
            if linear.lowercased() == "no" { continue }
            if let idref = el.attribute(forName: "idref")?.stringValue {
                result.append(idref)
            }
        }
        return result
    }

    private func firstChild(_ el: XMLElement, localName: String) -> XMLElement? {
        for child in el.children ?? [] {
            if let e = child as? XMLElement,
               (e.localName ?? e.name ?? "") == localName {
                return e
            }
        }
        return nil
    }

    private func extractChapterTitle(data: Data) -> String? {
        // Try to pull the first <h1>/<h2>/<h3>/<title> content.
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        let patterns = [
            #"<h1[^>]*>(.*?)</h1>"#,
            #"<h2[^>]*>(.*?)</h2>"#,
            #"<h3[^>]*>(.*?)</h3>"#,
            #"<title[^>]*>(.*?)</title>"#,
        ]
        for p in patterns {
            if let r = try? NSRegularExpression(pattern: p, options: [.caseInsensitive, .dotMatchesLineSeparators]),
               let m = r.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(m.range(at: 1), in: html) {
                // Strip inner tags
                let inner = String(html[range])
                let stripped = inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}
