import Foundation

enum XlsxConverterError: LocalizedError {
    case invalidXlsx(String)
    case noSheets

    var errorDescription: String? {
        switch self {
        case .invalidXlsx(let msg): return "XLSX 解析失败: \(msg)"
        case .noSheets: return "XLSX 中没有可读的 sheet"
        }
    }
}

/// XLSX → Markdown tables (one per sheet).
struct XlsxConverter {
    func convert(url: URL) throws -> String {
        let tempDir = try ZipExtractor.extract(url: url)
        defer { ZipExtractor.cleanup(tempDir: tempDir) }

        // 1. Shared strings table (may or may not exist)
        let sharedStrings = parseSharedStrings(dir: tempDir)

        // 2. Workbook → sheet list (name, rId)
        let sheets = parseWorkbook(dir: tempDir)
        guard !sheets.isEmpty else { throw XlsxConverterError.noSheets }

        // 3. Workbook rels → rId → target path
        let rels = parseWorkbookRels(dir: tempDir)

        // 4. For each sheet: parse and render
        var output = ""
        for (i, sheet) in sheets.enumerated() {
            guard let target = rels[sheet.rId] else { continue }
            // Resolve path relative to xl/
            let sheetPath = resolveSheetPath(target: target)
            let sheetURL = tempDir.appendingPathComponent("xl/\(sheetPath)")
            guard FileManager.default.fileExists(atPath: sheetURL.path),
                  let data = try? Data(contentsOf: sheetURL) else { continue }

            let rows = parseSheet(data: data, sharedStrings: sharedStrings)
            guard !rows.isEmpty else { continue }

            if i > 0 { output += "\n---\n\n" }
            output += "## \(sheet.name)\n\n"
            output += renderTable(rows: rows)
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: - Shared strings

    private func parseSharedStrings(dir: URL) -> [String] {
        let ssURL = dir.appendingPathComponent("xl/sharedStrings.xml")
        guard FileManager.default.fileExists(atPath: ssURL.path),
              let data = try? Data(contentsOf: ssURL) else {
            return []
        }
        let handler = SharedStringsHandler()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.strings
    }

    // MARK: - Workbook

    private struct SheetInfo {
        let name: String
        let rId: String
    }

    private func parseWorkbook(dir: URL) -> [SheetInfo] {
        let wbURL = dir.appendingPathComponent("xl/workbook.xml")
        guard FileManager.default.fileExists(atPath: wbURL.path),
              let data = try? Data(contentsOf: wbURL),
              let doc = try? XMLDocument(data: data, options: []),
              let root = doc.rootElement() else {
            return []
        }

        var result: [SheetInfo] = []
        for child in root.children ?? [] {
            guard let el = child as? XMLElement,
                  (el.localName ?? el.name ?? "") == "sheets" else { continue }
            for sh in el.children ?? [] {
                guard let sEl = sh as? XMLElement,
                      (sEl.localName ?? sEl.name ?? "") == "sheet" else { continue }
                let name = sEl.attribute(forName: "name")?.stringValue ?? "Sheet"
                let rId = sEl.attribute(forName: "r:id")?.stringValue
                    ?? sEl.attribute(forName: "id")?.stringValue
                    ?? ""
                result.append(SheetInfo(name: name, rId: rId))
            }
        }
        return result
    }

    private func parseWorkbookRels(dir: URL) -> [String: String] {
        let relsURL = dir.appendingPathComponent("xl/_rels/workbook.xml.rels")
        guard FileManager.default.fileExists(atPath: relsURL.path),
              let data = try? Data(contentsOf: relsURL),
              let doc = try? XMLDocument(data: data, options: []),
              let root = doc.rootElement() else {
            return [:]
        }

        var result: [String: String] = [:]
        for child in root.children ?? [] {
            guard let el = child as? XMLElement,
                  (el.localName ?? el.name ?? "") == "Relationship",
                  let id = el.attribute(forName: "Id")?.stringValue,
                  let target = el.attribute(forName: "Target")?.stringValue else { continue }
            result[id] = target
        }
        return result
    }

    private func resolveSheetPath(target: String) -> String {
        // target often looks like "worksheets/sheet1.xml" — relative to xl/
        // sometimes "/xl/worksheets/sheet1.xml" or "../worksheets/..."
        if target.hasPrefix("/xl/") {
            return String(target.dropFirst(4))
        }
        if target.hasPrefix("/") {
            return String(target.dropFirst())
        }
        if target.hasPrefix("../") {
            return String(target.dropFirst(3))
        }
        return target
    }

    // MARK: - Sheet

    private func parseSheet(data: Data, sharedStrings: [String]) -> [[String]] {
        let handler = SheetHandler(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.finish()
    }

    // MARK: - Table rendering

    private func renderTable(rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "" }
        let colCount = rows.map(\.count).max() ?? 0
        guard colCount > 0 else { return "" }

        let padded = rows.map { row -> [String] in
            var r = row
            while r.count < colCount { r.append("") }
            return r
        }

        // Use the first row as header (Excel tables don't mark headers explicitly)
        let header = padded[0].map { escapeCell($0) }
        let body = padded.dropFirst().map { $0.map { escapeCell($0) } }

        var md = "| " + header.joined(separator: " | ") + " |\n"
        md += "|" + String(repeating: " --- |", count: colCount) + "\n"
        for row in body {
            md += "| " + row.joined(separator: " | ") + " |\n"
        }
        return md + "\n"
    }

    private func escapeCell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - SharedStrings SAX handler

private class SharedStringsHandler: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var currentText = ""
    private var inSi = false
    private var inT = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = localName(elementName)
        if name == "si" {
            inSi = true
            currentText = ""
        } else if name == "t" && inSi {
            inT = true
        } else if name == "rPh" {
            // Phonetic runs: skip
            inT = false
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        if name == "si" {
            strings.append(currentText)
            inSi = false
        } else if name == "t" {
            inT = false
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inT { currentText += string }
    }

    private func localName(_ s: String) -> String {
        if let colon = s.firstIndex(of: ":") {
            return String(s[s.index(after: colon)...])
        }
        return s
    }
}

// MARK: - Sheet SAX handler

private class SheetHandler: NSObject, XMLParserDelegate {
    let sharedStrings: [String]
    private var rows: [[String]] = []
    private var currentRow: [String: String] = [:]  // col letter → value
    private var maxColInRow = 0

    // Cell state
    private var currentCellRef = ""  // e.g. "A1"
    private var currentCellType = ""  // "s", "str", "b", "inlineStr", ""
    private var inValue = false
    private var valueBuffer = ""
    private var inInlineString = false
    private var inlineStringBuffer = ""
    private var inT = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
        super.init()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = localName(elementName)
        switch name {
        case "row":
            currentRow = [:]
            maxColInRow = 0
        case "c":
            currentCellRef = attributeDict["r"] ?? ""
            currentCellType = attributeDict["t"] ?? ""
            valueBuffer = ""
            inlineStringBuffer = ""
        case "v":
            inValue = true
            valueBuffer = ""
        case "is":
            inInlineString = true
            inlineStringBuffer = ""
        case "t":
            inT = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        switch name {
        case "v":
            inValue = false
        case "is":
            inInlineString = false
        case "t":
            inT = false
        case "c":
            let col = columnLettersFrom(cellRef: currentCellRef)
            let colIdx = columnIndex(from: col)
            let resolved: String
            switch currentCellType {
            case "s":
                if let idx = Int(valueBuffer), idx >= 0, idx < sharedStrings.count {
                    resolved = sharedStrings[idx]
                } else {
                    resolved = valueBuffer
                }
            case "inlineStr":
                resolved = inlineStringBuffer
            case "b":
                resolved = (valueBuffer == "1") ? "TRUE" : "FALSE"
            default:
                resolved = valueBuffer
            }
            if !resolved.isEmpty {
                currentRow[col] = resolved
                if colIdx > maxColInRow { maxColInRow = colIdx }
            }
        case "row":
            // Flatten map into ordered array (by column)
            if !currentRow.isEmpty {
                var arr: [String] = []
                for i in 0...maxColInRow {
                    let letter = columnLetters(index: i)
                    arr.append(currentRow[letter] ?? "")
                }
                rows.append(arr)
            } else {
                rows.append([])
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue {
            valueBuffer += string
        }
        if inInlineString && inT {
            inlineStringBuffer += string
        }
    }

    func finish() -> [[String]] {
        // Drop trailing empty rows
        var result = rows
        while let last = result.last, last.allSatisfy({ $0.isEmpty }) {
            result.removeLast()
        }
        return result
    }

    private func localName(_ s: String) -> String {
        if let colon = s.firstIndex(of: ":") {
            return String(s[s.index(after: colon)...])
        }
        return s
    }

    private func columnLettersFrom(cellRef: String) -> String {
        var letters = ""
        for ch in cellRef {
            if ch.isLetter { letters.append(ch) } else { break }
        }
        return letters.uppercased()
    }

    private func columnIndex(from letters: String) -> Int {
        var result = 0
        for ch in letters {
            guard let ascii = ch.asciiValue else { continue }
            result = result * 26 + Int(ascii - 64)
        }
        return result - 1
    }

    private func columnLetters(index: Int) -> String {
        var n = index
        var letters = ""
        repeat {
            let rem = n % 26
            letters = String(UnicodeScalar(65 + rem)!) + letters
            n = n / 26 - 1
        } while n >= 0
        return letters
    }
}
