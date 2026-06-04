import Foundation

// MARK: - Errors

enum CsvConverterError: LocalizedError {
    case readFailed(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .readFailed(let msg): return "CSV 读取失败: \(msg)"
        case .empty:               return "CSV 文件为空"
        }
    }
}

// MARK: - Converter
//
// CSV / TSV → Markdown table. Quoted-field aware (handles commas and
// newlines inside double-quoted cells; "" escapes an embedded quote).
//
// Detection: tab as delimiter for `.tsv`, comma otherwise. For `.csv` files
// that actually use semicolons (European convention), we sniff the first
// non-quoted line and pick `;` if it dominates.

struct CsvConverter {
    func convert(url: URL) throws -> String {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw CsvConverterError.readFailed(error.localizedDescription) }

        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        guard !text.isEmpty else { throw CsvConverterError.empty }

        let ext = url.pathExtension.lowercased()
        let delimiter: Character = (ext == "tsv") ? "\t" : sniffDelimiter(text)

        let rows = parse(text, delimiter: delimiter)
        guard !rows.isEmpty else { throw CsvConverterError.empty }

        let title = url.deletingPathExtension().lastPathComponent
        return "# \(title)\n\n" + renderTable(rows)
    }

    // MARK: - Delimiter Sniffing

    private func sniffDelimiter(_ text: String) -> Character {
        // Look at the first ~5 lines. If semicolons dominate over commas
        // outside quotes, treat as semicolon-delimited (European CSV).
        var commas = 0, semis = 0, inQuote = false, lines = 0
        for ch in text {
            if ch == "\"" { inQuote.toggle(); continue }
            if inQuote { continue }
            switch ch {
            case ",": commas += 1
            case ";": semis += 1
            case "\n":
                lines += 1
                if lines >= 5 { break }
            default: break
            }
        }
        return semis > commas ? ";" : ","
    }

    // MARK: - CSV Parser (quote-aware)

    private func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuote = false
        var i = text.startIndex

        while i < text.endIndex {
            let c = text[i]
            if inQuote {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex && text[next] == "\"" {
                        field.append("\"")    // "" → escaped quote
                        i = next
                    } else {
                        inQuote = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuote = true
                case delimiter:
                    row.append(field); field = ""
                case "\r":
                    break                     // swallow, \r\n handled by \n
                case "\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                default:
                    field.append(c)
                }
            }
            i = text.index(after: i)
        }
        // Trailing field / row
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    // MARK: - Render

    private func renderTable(_ rows: [[String]]) -> String {
        let cols = rows.map(\.count).max() ?? 0
        guard cols > 0 else { return "" }

        // Pad ragged rows to the max width so the Markdown table is rectangular.
        let normalized = rows.map { r -> [String] in
            var nr = r
            while nr.count < cols { nr.append("") }
            return nr.map(escapeCell)
        }

        var md = "| " + normalized[0].joined(separator: " | ") + " |\n"
        md += "| " + Array(repeating: "---", count: cols).joined(separator: " | ") + " |\n"
        for row in normalized.dropFirst() {
            md += "| " + row.joined(separator: " | ") + " |\n"
        }
        return md
    }

    private func escapeCell(_ s: String) -> String {
        // Pipes break Markdown tables. Newlines inside cells convert to <br>.
        s.replacingOccurrences(of: "|", with: "\\|")
         .replacingOccurrences(of: "\n", with: "<br>")
    }
}
