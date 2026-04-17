import Foundation

/// Streaming XHTML → Markdown converter.
///
/// Used by EpubConverter (per-chapter XHTML), HtmlConverter (standalone .html),
/// and MobiConverter (decompressed HTML payload).
///
/// Strategy: lenient HTML tokenizer (doesn't require well-formed XML), block/inline
/// state machine. Accepts arbitrary real-world HTML (not just XHTML).
struct XHtmlToMarkdown {

    enum Error: LocalizedError {
        case invalidData

        var errorDescription: String? {
            switch self {
            case .invalidData: return "Invalid HTML data"
            }
        }
    }

    /// Convert HTML/XHTML data to Markdown.
    /// - Parameter data: raw bytes (UTF-8 assumed; falls back to Latin-1 if not).
    static func convert(data: Data) throws -> String {
        let html = decode(data: data)
        return convert(html: html)
    }

    /// Convert HTML/XHTML string to Markdown.
    static func convert(html: String) -> String {
        let tokens = tokenize(html: html)
        var builder = MarkdownBuilder()
        for token in tokens {
            builder.feed(token: token)
        }
        return builder.finish()
    }

    // MARK: - Decoding

    private static func decode(data: Data) -> String {
        // Check for <meta charset=...> hint in first 4KB
        if let ascii = String(data: data.prefix(4096), encoding: .isoLatin1) {
            let lower = ascii.lowercased()
            if let range = lower.range(of: "charset="),
               let encoding = parseCharset(String(lower[range.upperBound...]).prefix(80).description),
               let s = String(data: data, encoding: encoding) {
                return s
            }
        }

        if let s = String(data: data, encoding: .utf8) { return s }

        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gb18030) { return s }

        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func parseCharset(_ s: String) -> String.Encoding? {
        // Extract charset value like: utf-8, gbk, gb2312, gb18030, iso-8859-1
        var val = ""
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                val.append(ch)
            } else {
                break
            }
        }
        switch val.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "utf-16", "utf16": return .utf16
        case "gbk", "gb2312", "gb18030":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "big5":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        case "iso-8859-1", "latin1": return .isoLatin1
        default: return nil
        }
    }

    // MARK: - Tokenizer

    enum Token {
        case text(String)
        case startTag(name: String, attrs: [String: String], selfClosing: Bool)
        case endTag(name: String)
        case comment
        case doctype
    }

    private static func tokenize(html: String) -> [Token] {
        var tokens: [Token] = []
        var i = html.startIndex
        let end = html.endIndex

        while i < end {
            let ch = html[i]
            if ch == "<" {
                // Comment <!-- ... -->
                if html.distance(from: i, to: end) >= 4,
                   html[html.index(i, offsetBy: 1)] == "!",
                   html[html.index(i, offsetBy: 2)] == "-",
                   html[html.index(i, offsetBy: 3)] == "-" {
                    if let closeRange = html.range(of: "-->", range: html.index(i, offsetBy: 4)..<end) {
                        tokens.append(.comment)
                        i = closeRange.upperBound
                        continue
                    } else {
                        break
                    }
                }
                // Doctype / other <!...>
                if html.distance(from: i, to: end) >= 2,
                   html[html.index(i, offsetBy: 1)] == "!" {
                    if let closeIdx = html[i..<end].firstIndex(of: ">") {
                        tokens.append(.doctype)
                        i = html.index(after: closeIdx)
                        continue
                    } else {
                        break
                    }
                }
                // CDATA / processing instruction <?...?>
                if html.distance(from: i, to: end) >= 2,
                   html[html.index(i, offsetBy: 1)] == "?" {
                    if let closeIdx = html[i..<end].range(of: "?>") {
                        i = closeIdx.upperBound
                        continue
                    } else {
                        break
                    }
                }

                // Normal tag
                if let closeIdx = findTagEnd(html: html, from: i) {
                    let tagContent = String(html[html.index(after: i)..<closeIdx])
                    if let tok = parseTag(tagContent) {
                        // Special handling: <script>, <style> → skip to matching close tag
                        if case let .startTag(name, _, selfClosing) = tok,
                           !selfClosing,
                           ["script", "style"].contains(name) {
                            tokens.append(tok)
                            let afterOpen = html.index(after: closeIdx)
                            if let endTagRange = findEndTag(html: html, name: name, from: afterOpen) {
                                // Skip content; don't emit as text
                                i = endTagRange.upperBound
                                tokens.append(.endTag(name: name))
                                continue
                            } else {
                                i = afterOpen
                                continue
                            }
                        }
                        tokens.append(tok)
                    }
                    i = html.index(after: closeIdx)
                } else {
                    // Malformed: treat '<' as text
                    tokens.append(.text(String(ch)))
                    i = html.index(after: i)
                }
            } else {
                // Accumulate text until next '<'
                var text = ""
                while i < end && html[i] != "<" {
                    text.append(html[i])
                    i = html.index(after: i)
                }
                let decoded = decodeEntities(text)
                if !decoded.isEmpty {
                    tokens.append(.text(decoded))
                }
            }
        }
        return tokens
    }

    private static func findTagEnd(html: String, from: String.Index) -> String.Index? {
        var i = html.index(after: from)
        var inQuote: Character? = nil
        while i < html.endIndex {
            let ch = html[i]
            if let q = inQuote {
                if ch == q { inQuote = nil }
            } else {
                if ch == "\"" || ch == "'" {
                    inQuote = ch
                } else if ch == ">" {
                    return i
                }
            }
            i = html.index(after: i)
        }
        return nil
    }

    private static func findEndTag(html: String, name: String, from: String.Index) -> Range<String.Index>? {
        let pattern = "</\(name)"
        var searchStart = from
        while let r = html.range(of: pattern, options: .caseInsensitive, range: searchStart..<html.endIndex) {
            // Find the '>' after this
            if let gt = html[r.upperBound..<html.endIndex].firstIndex(of: ">") {
                return r.lowerBound..<html.index(after: gt)
            }
            searchStart = r.upperBound
        }
        return nil
    }

    private static func parseTag(_ content: String) -> Token? {
        var s = content
        var isEnd = false
        var selfClosing = false

        if s.hasPrefix("/") {
            isEnd = true
            s = String(s.dropFirst())
        }
        if s.hasSuffix("/") {
            selfClosing = true
            s = String(s.dropLast())
        }

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Extract tag name
        var name = ""
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if ch.isLetter || ch.isNumber {
                name.append(Character(ch.lowercased()))
                idx = s.index(after: idx)
            } else {
                break
            }
        }
        guard !name.isEmpty else { return nil }

        if isEnd {
            return .endTag(name: name)
        }

        // Void elements are always self-closing in HTML
        let voidElements: Set<String> = ["br", "hr", "img", "meta", "link", "input", "area", "base", "col", "embed", "param", "source", "track", "wbr"]
        if voidElements.contains(name) {
            selfClosing = true
        }

        let attrs = parseAttributes(s[idx...])
        return .startTag(name: name, attrs: attrs, selfClosing: selfClosing)
    }

    private static func parseAttributes(_ s: Substring) -> [String: String] {
        var attrs: [String: String] = [:]
        var i = s.startIndex
        let end = s.endIndex

        while i < end {
            // Skip whitespace
            while i < end && s[i].isWhitespace { i = s.index(after: i) }
            if i >= end { break }

            // Attr name
            var name = ""
            while i < end {
                let ch = s[i]
                if ch.isWhitespace || ch == "=" || ch == "/" || ch == ">" { break }
                name.append(Character(ch.lowercased()))
                i = s.index(after: i)
            }
            if name.isEmpty {
                if i < end { i = s.index(after: i) }
                continue
            }

            // Skip whitespace
            while i < end && s[i].isWhitespace { i = s.index(after: i) }

            var value = ""
            if i < end && s[i] == "=" {
                i = s.index(after: i)
                while i < end && s[i].isWhitespace { i = s.index(after: i) }
                if i < end && (s[i] == "\"" || s[i] == "'") {
                    let quote = s[i]
                    i = s.index(after: i)
                    while i < end && s[i] != quote {
                        value.append(s[i])
                        i = s.index(after: i)
                    }
                    if i < end { i = s.index(after: i) }
                } else {
                    while i < end {
                        let ch = s[i]
                        if ch.isWhitespace || ch == ">" { break }
                        value.append(ch)
                        i = s.index(after: i)
                    }
                }
            }

            attrs[name] = decodeEntities(value)
        }
        return attrs
    }

    // MARK: - Entity decoding

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "copy": "©", "reg": "®", "trade": "™",
        "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "laquo": "«", "raquo": "»",
        "middot": "·", "bull": "•",
    ]

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var result = ""
        var i = text.startIndex
        let end = text.endIndex

        while i < end {
            let ch = text[i]
            if ch == "&",
               let semi = text[i..<end].firstIndex(of: ";"),
               text.distance(from: i, to: semi) < 12 {
                let entity = String(text[text.index(after: i)..<semi])
                if entity.hasPrefix("#") {
                    let numPart = String(entity.dropFirst())
                    var scalar: UInt32?
                    if numPart.hasPrefix("x") || numPart.hasPrefix("X") {
                        scalar = UInt32(numPart.dropFirst(), radix: 16)
                    } else {
                        scalar = UInt32(numPart)
                    }
                    if let s = scalar, let u = Unicode.Scalar(s) {
                        result.append(Character(u))
                        i = text.index(after: semi)
                        continue
                    }
                } else if let repl = namedEntities[entity] {
                    result.append(repl)
                    i = text.index(after: semi)
                    continue
                }
            }
            result.append(ch)
            i = text.index(after: i)
        }
        return result
    }

    // MARK: - Markdown builder (state machine)

    private struct MarkdownBuilder {
        var output = ""
        var current = ""  // current paragraph/line buffer (inline content)

        // Inline formatting counters (nested)
        var boldDepth = 0
        var italicDepth = 0
        var codeDepth = 0

        // Block state
        var headingLevel = 0  // 0 = not in heading
        var inPre = false
        var preBuffer = ""
        var inBlockquote = 0
        var linkHrefStack: [String] = []
        var linkTextStack: [String] = []

        // List state
        enum ListType { case ul, ol }
        struct ListFrame { var type: ListType; var index: Int }
        var listStack: [ListFrame] = []
        var listItemDepth = 0  // 0 = not in <li>

        // Table state
        var inTable = false
        var tableRows: [[String]] = []
        var currentRow: [String] = []
        var currentCell = ""
        var inTableHeader = false
        var tableHasHeaderRow = false

        // Image alt stack (we emit `![alt](src)` when we see <img>)

        mutating func feed(token: Token) {
            switch token {
            case .text(let text):
                handleText(text)
            case .startTag(let name, let attrs, let selfClosing):
                handleStartTag(name: name, attrs: attrs)
                if selfClosing {
                    handleEndTag(name: name)
                }
            case .endTag(let name):
                handleEndTag(name: name)
            case .comment, .doctype:
                break
            }
        }

        mutating func handleText(_ raw: String) {
            if inPre {
                preBuffer += raw
                return
            }
            // Collapse whitespace
            var text = raw
            text = text.replacingOccurrences(of: "\n", with: " ")
            text = text.replacingOccurrences(of: "\t", with: " ")
            while text.contains("  ") {
                text = text.replacingOccurrences(of: "  ", with: " ")
            }
            if text.isEmpty { return }

            if inTable {
                appendToCurrentCell(escapeInline(text))
                return
            }
            if !linkTextStack.isEmpty {
                linkTextStack[linkTextStack.count - 1] += escapeInline(text)
                return
            }

            current += escapeInline(text)
        }

        private func escapeInline(_ s: String) -> String {
            // Escape markdown special chars minimally — we don't want to corrupt URLs.
            // Only escape [, ], `, * in body text.
            var out = ""
            for ch in s {
                switch ch {
                case "\\", "`":
                    out.append("\\")
                    out.append(ch)
                default:
                    out.append(ch)
                }
            }
            return out
        }

        private mutating func appendToCurrentCell(_ s: String) {
            currentCell += s
        }

        mutating func handleStartTag(name: String, attrs: [String: String]) {
            switch name {
            case "p":
                flushBlock()
            case "br":
                if inTable {
                    appendToCurrentCell(" ")
                } else if !linkTextStack.isEmpty {
                    linkTextStack[linkTextStack.count - 1] += "\n"
                } else {
                    current += "  \n"  // MD line-break
                }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flushBlock()
                headingLevel = Int(String(name.dropFirst())) ?? 1
                current += String(repeating: "#", count: headingLevel) + " "
            case "strong", "b":
                if !inPre {
                    emitInline("**")
                    boldDepth += 1
                }
            case "em", "i":
                if !inPre {
                    emitInline("*")
                    italicDepth += 1
                }
            case "code":
                if !inPre {
                    emitInline("`")
                    codeDepth += 1
                }
            case "pre":
                flushBlock()
                inPre = true
                preBuffer = ""
            case "hr":
                flushBlock()
                output += "---\n\n"
            case "a":
                let href = attrs["href"] ?? ""
                linkHrefStack.append(href)
                linkTextStack.append("")
            case "img":
                let src = attrs["src"] ?? ""
                let alt = attrs["alt"] ?? ""
                let img = "![\(alt)](\(src))"
                if inTable { appendToCurrentCell(img) }
                else if !linkTextStack.isEmpty { linkTextStack[linkTextStack.count - 1] += img }
                else { current += img }
            case "blockquote":
                flushBlock()
                inBlockquote += 1
            case "ul":
                flushBlock()
                listStack.append(ListFrame(type: .ul, index: 0))
            case "ol":
                flushBlock()
                let start = Int(attrs["start"] ?? "") ?? 1
                listStack.append(ListFrame(type: .ol, index: start - 1))
            case "li":
                flushBlock()
                if var frame = listStack.last {
                    frame.index += 1
                    listStack[listStack.count - 1] = frame
                    let indent = String(repeating: "  ", count: max(0, listStack.count - 1))
                    let marker: String
                    switch frame.type {
                    case .ul: marker = "- "
                    case .ol: marker = "\(frame.index). "
                    }
                    current = indent + marker
                } else {
                    current = "- "
                }
                listItemDepth += 1
            case "table":
                flushBlock()
                inTable = true
                tableRows = []
                currentRow = []
                tableHasHeaderRow = false
            case "thead":
                tableHasHeaderRow = true
            case "tr":
                currentRow = []
            case "td":
                currentCell = ""
                inTableHeader = false
            case "th":
                currentCell = ""
                inTableHeader = true
                tableHasHeaderRow = true
            case "div", "section", "article", "header", "footer", "main", "nav", "aside":
                flushBlock()
            default:
                break
            }
        }

        mutating func handleEndTag(name: String) {
            switch name {
            case "p":
                flushBlock()
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flushBlock()
                headingLevel = 0
            case "strong", "b":
                if boldDepth > 0 {
                    emitInline("**")
                    boldDepth -= 1
                }
            case "em", "i":
                if italicDepth > 0 {
                    emitInline("*")
                    italicDepth -= 1
                }
            case "code":
                if codeDepth > 0 {
                    emitInline("`")
                    codeDepth -= 1
                }
            case "pre":
                if inPre {
                    let code = preBuffer
                    output += "```\n\(code.hasSuffix("\n") ? code : code + "\n")```\n\n"
                    preBuffer = ""
                    inPre = false
                }
            case "a":
                if !linkTextStack.isEmpty {
                    let linkText = linkTextStack.removeLast()
                    let href = linkHrefStack.isEmpty ? "" : linkHrefStack.removeLast()
                    let rendered: String
                    if href.isEmpty {
                        rendered = linkText
                    } else {
                        rendered = "[\(linkText)](\(href))"
                    }
                    if inTable {
                        appendToCurrentCell(rendered)
                    } else if !linkTextStack.isEmpty {
                        linkTextStack[linkTextStack.count - 1] += rendered
                    } else {
                        current += rendered
                    }
                }
            case "blockquote":
                flushBlock()
                inBlockquote = max(0, inBlockquote - 1)
            case "ul", "ol":
                flushBlock()
                if !listStack.isEmpty {
                    listStack.removeLast()
                }
                if listStack.isEmpty && !output.hasSuffix("\n\n") {
                    if !output.hasSuffix("\n") { output += "\n" }
                    output += "\n"
                }
            case "li":
                flushBlock()
                listItemDepth = max(0, listItemDepth - 1)
            case "td", "th":
                currentRow.append(currentCell.trimmingCharacters(in: .whitespaces))
                currentCell = ""
                inTableHeader = false
            case "tr":
                if !currentRow.isEmpty {
                    tableRows.append(currentRow)
                }
                currentRow = []
            case "table":
                flushTable()
                inTable = false
            case "div", "section", "article", "header", "footer", "main", "nav", "aside":
                flushBlock()
            default:
                break
            }
        }

        private mutating func emitInline(_ marker: String) {
            if inTable { appendToCurrentCell(marker) }
            else if !linkTextStack.isEmpty { linkTextStack[linkTextStack.count - 1] += marker }
            else { current += marker }
        }

        mutating func flushBlock() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                var prefix = ""
                if inBlockquote > 0 {
                    prefix = String(repeating: "> ", count: inBlockquote)
                }
                // For headings: current already has the # prefix
                // For list items: current already has the marker
                if headingLevel > 0 {
                    output += prefix + trimmed + "\n\n"
                } else if listItemDepth > 0 {
                    output += prefix + trimmed + "\n"
                } else {
                    output += prefix + trimmed + "\n\n"
                }
            }
            current = ""
        }

        mutating func flushTable() {
            guard !tableRows.isEmpty else { return }

            let colCount = tableRows.map(\.count).max() ?? 0
            guard colCount > 0 else { return }

            // Normalize row widths
            let padded = tableRows.map { row -> [String] in
                var r = row
                while r.count < colCount { r.append("") }
                return r
            }

            var md = ""
            let headerRow: [String]
            let bodyRows: [[String]]
            if tableHasHeaderRow && padded.count > 1 {
                headerRow = padded[0]
                bodyRows = Array(padded.dropFirst())
            } else {
                headerRow = (0..<colCount).map { _ in "" }
                bodyRows = padded
            }

            md += "| " + headerRow.joined(separator: " | ") + " |\n"
            md += "|" + String(repeating: " --- |", count: colCount) + "\n"
            for row in bodyRows {
                md += "| " + row.joined(separator: " | ") + " |\n"
            }
            md += "\n"
            output += md

            tableRows = []
            currentRow = []
        }

        mutating func finish() -> String {
            flushBlock()
            if inTable { flushTable() }
            // Collapse 3+ blank lines to 2
            var result = output
            while result.contains("\n\n\n") {
                result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
    }
}
