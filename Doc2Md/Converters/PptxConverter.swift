import Foundation

enum PptxConverterError: LocalizedError {
    case noSlides
    case extractionFailed

    var errorDescription: String? {
        switch self {
        case .noSlides:
            return "PPTX 中未找到幻灯片"
        case .extractionFailed:
            return "PPTX 解压失败"
        }
    }
}

struct PptxConverter {
    func convert(url: URL) throws -> String {
        let tempDir = try ZipExtractor.extract(url: url)
        defer { ZipExtractor.cleanup(tempDir: tempDir) }

        let slidesDir = tempDir.appendingPathComponent("ppt/slides")
        guard FileManager.default.fileExists(atPath: slidesDir.path) else {
            throw PptxConverterError.noSlides
        }

        // Enumerate slide files and sort by slide number
        let contents = try FileManager.default.contentsOfDirectory(
            at: slidesDir,
            includingPropertiesForKeys: nil
        )
        let slideFiles = contents
            .filter { $0.pathExtension.lowercased() == "xml" && $0.lastPathComponent.hasPrefix("slide") }
            .sorted { extractSlideNumber($0) < extractSlideNumber($1) }

        guard !slideFiles.isEmpty else {
            throw PptxConverterError.noSlides
        }

        var markdown = ""

        for (index, slideURL) in slideFiles.enumerated() {
            autoreleasepool {
                guard let data = try? Data(contentsOf: slideURL) else { return }
                let parser = SlideSAXParser()
                let slideText = parser.parse(data: data)

                if !slideText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let slideNum = index + 1
                    markdown += "## Slide \(slideNum)\n\n"
                    markdown += slideText + "\n\n"

                    if index < slideFiles.count - 1 {
                        markdown += "---\n\n"
                    }
                }
            }
        }

        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PptxConverterError.noSlides
        }

        return markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func extractSlideNumber(_ url: URL) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
        let numStr = name.replacingOccurrences(of: "slide", with: "")
        return Int(numStr) ?? 0
    }
}

// MARK: - SAX Parser for individual slide XML

private class SlideSAXParser: NSObject, XMLParserDelegate {
    private var markdown = ""
    private var elementStack: [String] = []

    // Text run state
    private var runText = ""
    private var runBold = false
    private var runItalic = false
    private var collectingText = false

    // Paragraph state
    private var paragraphText = ""
    private var inParagraph = false

    // Table state
    private var inTable = false
    private var tableRows: [[String]] = []
    private var currentRowCells: [String] = []
    private var currentCellText = ""

    func parse(data: Data) -> String {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.parse()
        return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let local = localName(elementName)
        elementStack.append(local)

        switch local {
        case "p":
            // <a:p> — paragraph in a text body
            if inContext("txBody") {
                inParagraph = true
                paragraphText = ""
            }

        case "r":
            // <a:r> — text run
            if inContext("txBody") {
                runText = ""
                runBold = false
                runItalic = false
            }

        case "rPr":
            // <a:rPr b="1" i="1"> — run properties
            if inContext("r") {
                if let b = attributeDict["b"], b == "1" { runBold = true }
                if let i = attributeDict["i"], i == "1" { runItalic = true }
            }

        case "t":
            // <a:t> — text content
            if inContext("r") {
                collectingText = true
            }

        case "br":
            // <a:br> — line break in paragraph
            if inParagraph {
                paragraphText += "  \n"
            }

        case "tbl":
            // <a:tbl> — table
            inTable = true
            tableRows = []

        case "tr":
            if inTable { currentRowCells = [] }

        case "tc":
            if inTable { currentCellText = "" }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let local = localName(elementName)

        defer {
            if elementStack.last == local { elementStack.removeLast() }
        }

        switch local {
        case "t":
            collectingText = false

        case "r":
            // End of run — format and append
            guard !runText.isEmpty else { return }
            var formatted = runText
            if runBold && runItalic {
                formatted = "***\(formatted)***"
            } else if runBold {
                formatted = "**\(formatted)**"
            } else if runItalic {
                formatted = "*\(formatted)*"
            }

            if inTable && inContext("tc") {
                currentCellText += formatted
            } else {
                paragraphText += formatted
            }

        case "p":
            guard inParagraph else { return }
            inParagraph = false

            if inTable && inContext("tc") {
                if !currentCellText.isEmpty && !paragraphText.isEmpty {
                    currentCellText += " "
                }
                currentCellText += paragraphText
            } else {
                let trimmed = paragraphText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    markdown += trimmed + "\n\n"
                }
            }
            paragraphText = ""

        case "tc":
            if inTable {
                currentRowCells.append(currentCellText.trimmingCharacters(in: .whitespacesAndNewlines))
                currentCellText = ""
            }

        case "tr":
            if inTable { tableRows.append(currentRowCells) }

        case "tbl":
            if inTable {
                inTable = false
                markdown += formatTable(tableRows)
                tableRows = []
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingText {
            runText += string
        }
    }

    private func localName(_ name: String) -> String {
        if let idx = name.lastIndex(of: ":") {
            return String(name[name.index(after: idx)...])
        }
        return name
    }

    private func inContext(_ name: String) -> Bool {
        elementStack.contains(name)
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
}
