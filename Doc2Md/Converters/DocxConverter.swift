import Foundation

enum DocxConverterError: LocalizedError {
    case missingDocumentXml
    case xmlParsingFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingDocumentXml:
            return "DOCX 中缺少 word/document.xml"
        case .xmlParsingFailed(let msg):
            return "XML 解析失败: \(msg)"
        }
    }
}

struct DocxConverter {
    /// Set this on the converter instance to enable embedded image extraction.
    /// When non-nil, images in `word/media/*` are copied to `assetsDir` and the
    /// resulting Markdown references them by relative path. When nil, images
    /// are ignored (Markdown contains text only). String-mode output (CLI
    /// stdout) leaves this nil.
    var assetsDir: URL? = nil
    /// Path prefix to use when emitting `![](...)` references. Usually the
    /// basename of `assetsDir` (e.g. `report_assets`). When nil, paths are
    /// relative to assetsDir itself.
    var assetsRelativePrefix: String? = nil

    func convert(url: URL) throws -> String {
        let tempDir = try ZipExtractor.extract(url: url)
        defer { ZipExtractor.cleanup(tempDir: tempDir) }

        let relationships = parseRelationships(tempDir: tempDir)
        let numbering = parseNumbering(tempDir: tempDir)
        let imageRefs = extractImages(tempDir: tempDir)

        let docXmlURL = tempDir.appendingPathComponent("word/document.xml")
        guard FileManager.default.fileExists(atPath: docXmlURL.path) else {
            throw DocxConverterError.missingDocumentXml
        }

        let data = try Data(contentsOf: docXmlURL)
        let saxParser = DocxSAXParser(
            relationships: relationships,
            numbering: numbering,
            imageRefs: imageRefs
        )
        let markdown = try saxParser.parse(data: data)
        return markdown
    }

    // MARK: - Image Extraction
    //
    // Reads <Relationship Type="...image" Target="media/imageN.ext"> from
    // document.xml.rels, copies each media file from the unzipped temp dir
    // to assetsDir, and returns a [rId: markdownPath] map. If assetsDir
    // is nil, returns an empty map (images skipped).

    private func extractImages(tempDir: URL) -> [String: String] {
        guard let assetsDir = assetsDir else { return [:] }

        let relsURL = tempDir.appendingPathComponent("word/_rels/document.xml.rels")
        guard let doc = try? XMLDocument(contentsOf: relsURL, options: []),
              let root = doc.rootElement() else { return [:] }

        var imageRels: [(rId: String, target: String)] = []
        for child in root.children ?? [] {
            guard let el = child as? XMLElement,
                  (el.localName ?? el.name ?? "") == "Relationship",
                  let type = el.attribute(forName: "Type")?.stringValue,
                  type.contains("/image"),
                  let rId = el.attribute(forName: "Id")?.stringValue,
                  let target = el.attribute(forName: "Target")?.stringValue
            else { continue }
            imageRels.append((rId, target))
        }
        guard !imageRels.isEmpty else { return [:] }

        // Create assets dir
        try? FileManager.default.createDirectory(
            at: assetsDir, withIntermediateDirectories: true)

        var refs: [String: String] = [:]
        for (rId, target) in imageRels {
            // target is typically "media/image1.png" — strip "media/" prefix
            // for the output filename. Otherwise keep the basename only.
            let src = tempDir.appendingPathComponent("word/")
                .appendingPathComponent(target)
            let basename = src.lastPathComponent
            let dst = assetsDir.appendingPathComponent(basename)
            try? FileManager.default.removeItem(at: dst)
            do {
                try FileManager.default.copyItem(at: src, to: dst)
            } catch { continue }

            let mdPath: String
            if let prefix = assetsRelativePrefix {
                mdPath = "\(prefix)/\(basename)"
            } else {
                mdPath = basename
            }
            refs[rId] = mdPath
        }
        return refs
    }

    // MARK: - Relationships (small file, XMLDocument OK)

    private func parseRelationships(tempDir: URL) -> [String: String] {
        var rels: [String: String] = [:]
        let relsURL = tempDir.appendingPathComponent("word/_rels/document.xml.rels")
        guard let doc = try? XMLDocument(contentsOf: relsURL, options: []),
              let root = doc.rootElement() else { return rels }

        for child in root.children ?? [] {
            guard let el = child as? XMLElement,
                  (el.localName ?? el.name ?? "") == "Relationship",
                  let rId = el.attribute(forName: "Id")?.stringValue,
                  let target = el.attribute(forName: "Target")?.stringValue,
                  el.attribute(forName: "TargetMode")?.stringValue == "External" else { continue }
            rels[rId] = target
        }
        return rels
    }

    // MARK: - Numbering (small file, XMLDocument OK)

    private func parseNumbering(tempDir: URL) -> [String: String] {
        var numMap: [String: String] = [:]
        let numURL = tempDir.appendingPathComponent("word/numbering.xml")
        guard let doc = try? XMLDocument(contentsOf: numURL, options: []),
              let root = doc.rootElement() else { return numMap }

        func attrVal(_ el: XMLElement, _ name: String) -> String? {
            el.attribute(forName: "w:\(name)")?.stringValue
            ?? el.attribute(forName: name)?.stringValue
        }
        func findChild(_ el: XMLElement, _ name: String) -> XMLElement? {
            for c in el.children ?? [] {
                guard let e = c as? XMLElement,
                      (e.localName ?? e.name ?? "") == name else { continue }
                return e
            }
            return nil
        }

        var abstractMap: [String: [(String, String)]] = [:]
        for child in root.children ?? [] {
            guard let absEl = child as? XMLElement,
                  (absEl.localName ?? absEl.name ?? "") == "abstractNum",
                  let absId = attrVal(absEl, "abstractNumId") else { continue }
            var lvlFormats: [(String, String)] = []
            for lvlChild in absEl.children ?? [] {
                guard let lvlEl = lvlChild as? XMLElement,
                      (lvlEl.localName ?? lvlEl.name ?? "") == "lvl" else { continue }
                let ilvl = attrVal(lvlEl, "ilvl") ?? "0"
                let fmt = findChild(lvlEl, "numFmt").flatMap { attrVal($0, "val") } ?? "decimal"
                lvlFormats.append((ilvl, fmt))
            }
            abstractMap[absId] = lvlFormats
        }

        for child in root.children ?? [] {
            guard let numEl = child as? XMLElement,
                  (numEl.localName ?? numEl.name ?? "") == "num",
                  let numId = attrVal(numEl, "numId") else { continue }
            guard let absIdEl = findChild(numEl, "abstractNumId"),
                  let absIdVal = attrVal(absIdEl, "val"),
                  let formats = abstractMap[absIdVal] else { continue }
            for (ilvl, fmt) in formats {
                numMap["\(numId)-\(ilvl)"] = fmt
            }
        }

        return numMap
    }
}

// MARK: - SAX Parser for document.xml (handles any size)

class DocxSAXParser: NSObject, XMLParserDelegate {
    private let relationships: [String: String]
    private let numbering: [String: String]
    /// Map of relationship ID → markdown path for embedded images.
    /// Empty when image extraction is disabled.
    private let imageRefs: [String: String]

    private var markdown = ""
    private var elementStack: [String] = []
    private var orderedListCounters: [String: Int] = [:]

    // Paragraph state
    private var inBody = false
    private var paragraphText = ""
    private var headingLevel: Int? = nil
    private var listNumId: String? = nil
    private var listIlvl: String? = nil
    /// True when the paragraph's pStyle is a known "list paragraph" style
    /// (e.g. "ListParagraph", "ListBullet", "ListNumber"). Some Word
    /// documents apply these styles without an inline <w:numPr>, in which
    /// case the paragraph is still semantically a list item.
    private var listStyleKind: ListStyleKind? = nil

    enum ListStyleKind { case bullet, number }

    // Run state
    private var runText = ""
    private var runBold = false
    private var runItalic = false
    private var runStrike = false
    private var collectingText = false

    // Hyperlink state
    private var hyperlinkRId: String? = nil

    // Table state
    private var inTable = false
    private var tableRows: [[String]] = []
    private var currentRowCells: [String] = []
    private var currentCellText = ""

    // Error
    private var parseError: Error?

    init(relationships: [String: String],
         numbering: [String: String],
         imageRefs: [String: String] = [:]) {
        self.relationships = relationships
        self.numbering = numbering
        self.imageRefs = imageRefs
    }

    func parse(data: Data) throws -> String {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.parse()

        if let error = parseError ?? parser.parserError {
            throw DocxConverterError.xmlParsingFailed(error.localizedDescription)
        }

        return cleanupMarkdown(markdown)
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let local = localName(elementName)
        elementStack.append(local)

        switch local {
        case "body":
            inBody = true

        case "p":
            guard inBody else { return }
            paragraphText = ""
            headingLevel = nil
            listNumId = nil
            listIlvl = nil
            listStyleKind = nil

        case "pStyle":
            guard inContext("pPr") else { return }
            if let val = attributeDict["w:val"] ?? attributeDict["val"] {
                headingLevel = parseHeadingLevel(val)
                if headingLevel == nil {
                    listStyleKind = parseListStyle(val)
                }
            }

        case "outlineLvl":
            guard inContext("pPr"), headingLevel == nil else { return }
            if let val = attributeDict["w:val"] ?? attributeDict["val"],
               let lvl = Int(val), lvl >= 0 && lvl <= 5 {
                headingLevel = lvl + 1
            }

        case "ilvl":
            guard inContext("numPr") else { return }
            listIlvl = attributeDict["w:val"] ?? attributeDict["val"] ?? "0"

        case "numId":
            guard inContext("numPr") else { return }
            listNumId = attributeDict["w:val"] ?? attributeDict["val"]

        case "r":
            guard inBody else { return }
            runText = ""
            runBold = false
            runItalic = false
            runStrike = false

        case "b":
            guard inContext("rPr") else { return }
            let val = attributeDict["w:val"] ?? attributeDict["val"]
            if val != "false" && val != "0" {
                runBold = true
            }

        case "i":
            guard inContext("rPr") else { return }
            let val = attributeDict["w:val"] ?? attributeDict["val"]
            if val != "false" && val != "0" {
                runItalic = true
            }

        case "strike":
            guard inContext("rPr") else { return }
            let val = attributeDict["w:val"] ?? attributeDict["val"]
            if val != "false" && val != "0" {
                runStrike = true
            }

        case "t":
            guard inContext("r") else { return }
            collectingText = true

        case "br":
            guard inContext("r") else { return }
            let brType = attributeDict["w:type"] ?? attributeDict["type"]
            if brType == "page" {
                runText += "\n\n---\n\n"
            } else {
                runText += "  \n"
            }

        case "tab":
            guard inContext("r") else { return }
            runText += "\t"

        case "hyperlink":
            guard inBody else { return }
            hyperlinkRId = attributeDict["r:id"] ?? attributeDict["id"]

        case "blip":
            // DrawingML <a:blip r:embed="rIdN" /> — emit ![](path) reference
            // if the rel ID has a known media target. We append it to the
            // current paragraph (or table cell) text so the image appears at
            // roughly the right point in the flow.
            guard inBody else { return }
            let rId = attributeDict["r:embed"] ?? attributeDict["embed"]
                  ?? attributeDict["r:link"]  ?? attributeDict["link"]
            if let rId = rId, let path = imageRefs[rId] {
                let marker = "![](\(path))"
                if inTable && inContext("tc") {
                    currentCellText += marker
                } else {
                    paragraphText += marker
                }
            }

        case "tbl":
            guard inBody else { return }
            inTable = true
            tableRows = []

        case "tr":
            guard inTable else { return }
            currentRowCells = []

        case "tc":
            guard inTable else { return }
            currentCellText = ""

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let local = localName(elementName)

        defer {
            if let last = elementStack.last, last == local {
                elementStack.removeLast()
            }
        }

        switch local {
        case "body":
            inBody = false

        case "t":
            collectingText = false

        case "r":
            guard inBody else { return }
            let formatted = formatRun(runText, bold: runBold, italic: runItalic, strike: runStrike)
            if inTable && inContext("tc") {
                currentCellText += formatted
            } else {
                paragraphText += formatted
            }

        case "hyperlink":
            guard inBody else { return }
            if let rId = hyperlinkRId, let url = relationships[rId], !paragraphText.isEmpty {
                // Find the text added by runs inside this hyperlink
                // The runs have already appended to paragraphText or currentCellText
                // We need to wrap the most recent addition
                // Simple approach: track what was added
            }
            hyperlinkRId = nil

        case "p":
            guard inBody else { return }
            if inTable && inContext("tc") {
                if !currentCellText.isEmpty {
                    currentCellText += " "
                }
                // Text already in currentCellText from runs
                return
            }

            var line = ""
            if let lvl = headingLevel {
                line += String(repeating: "#", count: lvl) + " "
            }
            if let numId = listNumId, numId != "0" {
                let ilvl = listIlvl ?? "0"
                let indent = String(repeating: "  ", count: Int(ilvl) ?? 0)
                let key = "\(numId)-\(ilvl)"
                let fmt = numbering[key] ?? "decimal"
                if fmt == "bullet" {
                    line += "\(indent)- "
                } else {
                    let counter = (orderedListCounters[key] ?? 0) + 1
                    orderedListCounters[key] = counter
                    line += "\(indent)\(counter). "
                }
            } else if let kind = listStyleKind {
                // Paragraph uses a "list paragraph" pStyle but has no inline
                // numPr. Apply a default bullet/number marker so the output
                // still reads as a list. This catches the common pattern of
                // Word docs that apply "ListParagraph" without binding to a
                // numbering definition.
                switch kind {
                case .bullet:
                    line += "- "
                case .number:
                    let key = "style-number"
                    let counter = (orderedListCounters[key] ?? 0) + 1
                    orderedListCounters[key] = counter
                    line += "\(counter). "
                }
            }
            line += paragraphText
            // Markdown spec: paragraphs are separated by a BLANK LINE (\n\n).
            // A single \n collapses adjacent paragraphs into one render block
            // (soft break). We always emit \n\n; consecutive list items become
            // a "loose list" (still valid Markdown). cleanupMarkdown below
            // collapses 3+ newlines back to 2, so over-spacing is bounded.
            markdown += line + "\n\n"

        case "tc":
            guard inTable else { return }
            currentRowCells.append(currentCellText.trimmingCharacters(in: .whitespacesAndNewlines))
            currentCellText = ""

        case "tr":
            guard inTable else { return }
            tableRows.append(currentRowCells)

        case "tbl":
            guard inTable else { return }
            inTable = false
            markdown += formatTable(tableRows)
            tableRows = []

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingText {
            runText += string
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        parseError = error
    }

    // MARK: - Helpers

    private func localName(_ name: String) -> String {
        if let idx = name.lastIndex(of: ":") {
            return String(name[name.index(after: idx)...])
        }
        return name
    }

    private func inContext(_ elementName: String) -> Bool {
        elementStack.contains(elementName)
    }

    /// Recognise common Word list paragraph styles. Returns nil if the style
    /// isn't a list style.
    ///
    /// Word's "List Paragraph" style is the most common offender: it marks
    /// a paragraph as a list item visually, but the actual numbering binding
    /// (numId / ilvl) is sometimes missing from the inline pPr, so a strict
    /// numPr-only parser would render it as plain text.
    private func parseListStyle(_ style: String) -> ListStyleKind? {
        let n = style.lowercased().replacingOccurrences(of: " ", with: "")
        // Default bullet styles
        if n == "listparagraph" || n == "listbullet" || n == "bulletlist"
            || n.hasPrefix("listbullet") || n == "ipl" {
            return .bullet
        }
        // Numbered styles
        if n == "listnumber" || n == "numberlist" || n.hasPrefix("listnumber") {
            return .number
        }
        return nil
    }

    private func parseHeadingLevel(_ style: String) -> Int? {
        let normalized = style.lowercased().replacingOccurrences(of: " ", with: "")
        if normalized == "title" { return 1 }
        if normalized == "subtitle" { return 2 }
        if normalized.hasPrefix("heading") || normalized.hasPrefix("titre") {
            let numStr = normalized.replacingOccurrences(of: "heading", with: "")
                                   .replacingOccurrences(of: "titre", with: "")
            if let level = Int(numStr), level >= 1 && level <= 6 {
                return level
            }
        }
        return nil
    }

    private func formatRun(_ text: String, bold: Bool, italic: Bool, strike: Bool) -> String {
        guard !text.isEmpty else { return "" }
        var result = text
        if bold && italic {
            result = "***\(result)***"
        } else if bold {
            result = "**\(result)**"
        } else if italic {
            result = "*\(result)*"
        }
        if strike {
            result = "~~\(result)~~"
        }
        return result
    }

    private func formatTable(_ rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "" }
        let maxCols = rows.map { $0.count }.max() ?? 0
        guard maxCols > 0 else { return "" }

        let normalized = rows.map { row -> [String] in
            var r = row
            while r.count < maxCols { r.append("") }
            return r
        }

        var table = "| " + normalized[0].joined(separator: " | ") + " |\n"
        table += "| " + normalized[0].map { _ in "---" }.joined(separator: " | ") + " |\n"
        for row in normalized.dropFirst() {
            table += "| " + row.joined(separator: " | ") + " |\n"
        }
        return table + "\n"
    }

    private func cleanupMarkdown(_ md: String) -> String {
        var result = md
        // Merge adjacent formatting markers
        result = result.replacingOccurrences(of: "******", with: "")
        result = result.replacingOccurrences(of: "****", with: "")
        // Remove excessive blank lines
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
