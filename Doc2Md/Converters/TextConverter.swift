import Foundation

enum TextConverterError: LocalizedError {
    case readFailed(String)
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .readFailed(let msg):
            return "文本读取失败: \(msg)"
        case .emptyFile:
            return "文件为空"
        }
    }
}

/// Plain-text and Markdown pass-through converter.
///
/// - `.md` / `.markdown`: normalize line endings, return as-is (content is already Markdown).
/// - `.txt`: normalize line endings and light wrapping; no structural change.
///
/// Encoding detection order: UTF-8 → GB18030 → Latin-1 (never fails).
struct TextConverter {
    func convert(url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TextConverterError.readFailed(error.localizedDescription)
        }

        guard !data.isEmpty else {
            throw TextConverterError.emptyFile
        }

        let content = decodeText(data: data)
        let normalized = normalizeLineEndings(content)

        let ext = url.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" {
            // Markdown: pass through after line-ending normalization.
            return normalized.hasSuffix("\n") ? normalized : normalized + "\n"
        }

        // .txt: light clean — collapse 3+ blank lines to 2, trim trailing whitespace per line.
        return cleanupPlainText(normalized)
    }

    // MARK: - Decoding

    private func decodeText(data: Data) -> String {
        // Strip UTF-8 BOM if present
        var workingData = data
        if data.count >= 3,
           data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            workingData = data.subdata(in: 3..<data.count)
        }

        // UTF-16 BOM detection
        if data.count >= 2 {
            if data[0] == 0xFF && data[1] == 0xFE,
               let s = String(data: data, encoding: .utf16LittleEndian) {
                return s
            }
            if data[0] == 0xFE && data[1] == 0xFF,
               let s = String(data: data, encoding: .utf16BigEndian) {
                return s
            }
        }

        // Try UTF-8 first
        if let s = String(data: workingData, encoding: .utf8) {
            return s
        }

        // GB18030 (covers GBK, GB2312, Big5 subsets on most real-world CN files)
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: workingData, encoding: gb18030) {
            return s
        }

        // Fallback: Latin-1 never fails
        return String(data: workingData, encoding: .isoLatin1) ?? ""
    }

    // MARK: - Normalization

    private func normalizeLineEndings(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
        result = result.replacingOccurrences(of: "\r", with: "\n")
        return result
    }

    private func cleanupPlainText(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")

        let trimmed = lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }

        var result: [String] = []
        var blankCount = 0
        for line in trimmed {
            if line.isEmpty {
                blankCount += 1
                if blankCount <= 2 {
                    result.append(line)
                }
            } else {
                blankCount = 0
                result.append(line)
            }
        }

        let joined = result.joined(separator: "\n")
        return joined.hasSuffix("\n") ? joined : joined + "\n"
    }
}
