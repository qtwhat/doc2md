import Foundation

enum OdtConverterError: LocalizedError {
    case missingContentXml
    case parsingFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingContentXml: return "ODT 中缺少 content.xml"
        case .parsingFailed(let msg): return "ODT 解析失败: \(msg)"
        }
    }
}

/// ODT (OpenDocument Text) → Markdown.
///
/// ODT is a ZIP containing `content.xml` (body) and `styles.xml` (style defs).
/// We parse both with a SAX parser to extract structure (headings, paragraphs,
/// lists, links, tables) while looking up style-name → bold/italic from `styles.xml`.
struct OdtConverter {
    func convert(url: URL) throws -> String {
        let tempDir = try ZipExtractor.extract(url: url)
        defer { ZipExtractor.cleanup(tempDir: tempDir) }

        let contentURL = tempDir.appendingPathComponent("content.xml")
        guard FileManager.default.fileExists(atPath: contentURL.path) else {
            throw OdtConverterError.missingContentXml
        }

        // Parse styles.xml (if present) for style-name → (bold, italic)
        let stylesURL = tempDir.appendingPathComponent("styles.xml")
        var styleMap: [String: (bold: Bool, italic: Bool)] = [:]
        if FileManager.default.fileExists(atPath: stylesURL.path),
           let stylesData = try? Data(contentsOf: stylesURL) {
            styleMap.merge(parseStyles(data: stylesData)) { _, new in new }
        }
        // Styles can also be embedded inline in content.xml — merged by parser below

        let data = try Data(contentsOf: contentURL)
        let parser = OdtSAXParser(styleMap: styleMap)
        return try parser.parse(data: data)
    }

    /// Parse style-name → (bold, italic) from styles.xml or content.xml <office:automatic-styles>.
    private func parseStyles(data: Data) -> [String: (bold: Bool, italic: Bool)] {
        let handler = OdtStyleHandler()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.styles
    }
}

// MARK: - Style handler (scans <style:style> entries)

private class OdtStyleHandler: NSObject, XMLParserDelegate {
    var styles: [String: (bold: Bool, italic: Bool)] = [:]
    private var currentStyleName: String?
    private var currentBold = false
    private var currentItalic = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let local = localName(elementName)
        if local == "style" {
            currentStyleName = attributeDict["style:name"] ?? attributeDict["name"]
            currentBold = false
            currentItalic = false
        } else if local == "text-properties" {
            let weight = attributeDict["fo:font-weight"] ?? attributeDict["font-weight"] ?? ""
            let style = attributeDict["fo:font-style"] ?? attributeDict["font-style"] ?? ""
            if weight == "bold" || weight == "700" { currentBold = true }
            if style == "italic" || style == "oblique" { currentItalic = true }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = localName(elementName)
        if local == "style", let name = currentStyleName {
            styles[name] = (currentBold, currentItalic)
            currentStyleName = nil
        }
    }

    private func localName(_ s: String) -> String {
        if let colon = s.firstIndex(of: ":") {
            return String(s[s.index(after: colon)...])
        }
        return s
    }
}

// MARK: - Main content parser

private class OdtSAXParser: NSObject, XMLParserDelegate {
    var styleMap: [String: (bold: Bool, italic: Bool)]

    init(styleMap: [String: (bold: Bool, italic: Bool)]) {
        self.styleMap = styleMap
        super.init()
    }

    // Block state
    private var output = ""
    private var currentLine = ""
    private var headingLevel = 0

    // Span formatting stack
    private var formatStack: [(bold: Bool, italic: Bool)] = []
    private var boldActiveCount = 0
    private var italicActiveCount = 0

    // Link state
    private var linkHrefStack: [String] = []
    private var linkTextStack: [String] = []

    // List state
    private enum ListType { case unordered, ordered }
    private var listStack: [(type: ListType, index: Int)] = []
    private var inListItem = false
    private var listItemMarkerApplied = false

    // Table state
    private var inTable = false
    private var tableRows: [[String]] = []
    private var currentRow: [String] = []
    private var currentCell = ""

    // Control
    private var parseError: Error?

    func parse(data: Data) throws -> String {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = self

        guard parser.parse() else {
            throw OdtConverterError.parsingFailed(parser.parserError?.localizedDescription ?? "unknown")
        }
        if let e = parseError { throw e }

        finishBlock()
        var result = output
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func localName(_ s: String) -> String {
        if let colon = s.firstIndex(of: ":") {
            return String(s[s.index(after: colon)...])
        }
        return s
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = localName(elementName)

        // Also pick up inline styles from <office:automatic-styles> embedded in content.xml
        if name == "style" {
            // Begin gathering inline style — subsequent <text-properties> will set flags.
            // We store to styleMap at endElement.
            pendingStyleName = attributeDict["style:name"] ?? attributeDict["name"]
            pendingBold = false
            pendingItalic = false
            return
        }
        if name == "text-properties" {
            let weight = attributeDict["fo:font-weight"] ?? attributeDict["font-weight"] ?? ""
            let style = attributeDict["fo:font-style"] ?? attributeDict["font-style"] ?? ""
            if weight == "bold" || weight == "700" { pendingBold = true }
            if style == "italic" || style == "oblique" { pendingItalic = true }
            return
        }

        switch name {
        case "h":
            finishBlock()
            let levelStr = attributeDict["text:outline-level"] ?? attributeDict["outline-level"] ?? "1"
            headingLevel = min(6, max(1, Int(levelStr) ?? 1))
            currentLine += String(repeating: "#", count: headingLevel) + " "
        case "p":
            finishBlock()
        case "span":
            let styleName = attributeDict["text:style-name"] ?? attributeDict["style-name"] ?? ""
            let st = styleMap[styleName] ?? (false, false)
            formatStack.append(st)
            if st.bold {
                if boldActiveCount == 0 { emitInline("**") }
                boldActiveCount += 1
            }
            if st.italic {
                if italicActiveCount == 0 { emitInline("*") }
                italicActiveCount += 1
            }
        case "a":
            let href = attributeDict["xlink:href"] ?? attributeDict["href"] ?? ""
            linkHrefStack.append(href)
            linkTextStack.append("")
        case "line-break":
            if inTable { currentCell += " " }
            else if !linkTextStack.isEmpty { linkTextStack[linkTextStack.count - 1] += " " }
            else { currentLine += "  \n" }
        case "s", "tab":
            // <text:s/> = space (optional c="N"), <text:tab/> = tab
            let count = Int(attributeDict["text:c"] ?? attributeDict["c"] ?? "1") ?? 1
            let ch = name == "tab" ? "\t" : " "
            let s = String(repeating: ch, count: count)
            if inTable { currentCell += s }
            else if !linkTextStack.isEmpty { linkTextStack[linkTextStack.count - 1] += s }
            else { currentLine += s }
        case "list":
            finishBlock()
            // Heuristic: default to unordered; ordered-list detection requires list-style inspection.
            let type: ListType = (attributeDict["text:continue-numbering"] != nil || attributeDict.keys.contains(where: { $0.contains("number") })) ? .ordered : .unordered
            listStack.append((type: type, index: 0))
        case "list-item":
            finishBlock()
            if var frame = listStack.last {
                frame.index += 1
                listStack[listStack.count - 1] = frame
                let indent = String(repeating: "  ", count: max(0, listStack.count - 1))
                let marker: String
                switch frame.type {
                case .unordered: marker = "- "
                case .ordered: marker = "\(frame.index). "
                }
                currentLine = indent + marker
            } else {
                currentLine = "- "
            }
            inListItem = true
            listItemMarkerApplied = true
        case "table":
            finishBlock()
            inTable = true
            tableRows = []
            currentRow = []
        case "table-row":
            currentRow = []
        case "table-cell":
            currentCell = ""
        default:
            break
        }
    }

    private var pendingStyleName: String?
    private var pendingBold = false
    private var pendingItalic = false

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)

        if name == "style" {
            if let styleName = pendingStyleName {
                // Merge if not already present (styles.xml takes precedence)
                if styleMap[styleName] == nil {
                    styleMap[styleName] = (pendingBold, pendingItalic)
                }
            }
            pendingStyleName = nil
            return
        }
        if name == "text-properties" {
            return
        }

        switch name {
        case "h":
            finishBlock()
            headingLevel = 0
        case "p":
            finishBlock()
        case "span":
            if !formatStack.isEmpty {
                let st = formatStack.removeLast()
                if st.italic {
                    italicActiveCount -= 1
                    if italicActiveCount == 0 { emitInline("*") }
                }
                if st.bold {
                    boldActiveCount -= 1
                    if boldActiveCount == 0 { emitInline("**") }
                }
            }
        case "a":
            if !linkTextStack.isEmpty {
                let text = linkTextStack.removeLast()
                let href = linkHrefStack.isEmpty ? "" : linkHrefStack.removeLast()
                let rendered = href.isEmpty ? text : "[\(text)](\(href))"
                if inTable { currentCell += rendered }
                else if !linkTextStack.isEmpty { linkTextStack[linkTextStack.count - 1] += rendered }
                else { currentLine += rendered }
            }
        case "list":
            finishBlock()
            if !listStack.isEmpty { listStack.removeLast() }
            if listStack.isEmpty && !output.hasSuffix("\n\n") {
                if !output.hasSuffix("\n") { output += "\n" }
                output += "\n"
            }
        case "list-item":
            finishBlock()
            inListItem = false
        case "table-cell":
            currentRow.append(currentCell.trimmingCharacters(in: .whitespaces))
            currentCell = ""
        case "table-row":
            if !currentRow.isEmpty { tableRows.append(currentRow) }
            currentRow = []
        case "table":
            flushTable()
            inTable = false
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let text = string
        if text.isEmpty { return }
        if inTable {
            currentCell += text
            return
        }
        if !linkTextStack.isEmpty {
            linkTextStack[linkTextStack.count - 1] += text
            return
        }
        currentLine += text
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }

    // MARK: Helpers

    private func emitInline(_ marker: String) {
        if inTable { currentCell += marker }
        else if !linkTextStack.isEmpty { linkTextStack[linkTextStack.count - 1] += marker }
        else { currentLine += marker }
    }

    private func finishBlock() {
        let trimmed = currentLine.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            if headingLevel > 0 || inListItem {
                output += trimmed + "\n"
                if headingLevel > 0 { output += "\n" }
            } else {
                output += trimmed + "\n\n"
            }
        }
        currentLine = ""
    }

    private func flushTable() {
        guard !tableRows.isEmpty else { return }
        let colCount = tableRows.map(\.count).max() ?? 0
        guard colCount > 0 else { return }

        let padded = tableRows.map { row -> [String] in
            var r = row
            while r.count < colCount { r.append("") }
            return r
        }

        var md = ""
        let header = padded[0]
        let body = Array(padded.dropFirst())
        md += "| " + header.joined(separator: " | ") + " |\n"
        md += "|" + String(repeating: " --- |", count: colCount) + "\n"
        for row in body {
            md += "| " + row.joined(separator: " | ") + " |\n"
        }
        md += "\n"
        output += md

        tableRows = []
    }
}
