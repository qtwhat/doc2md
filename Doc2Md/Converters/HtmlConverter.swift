import Foundation
import AppKit

enum HtmlConverterError: LocalizedError {
    case readFailed(String)
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .readFailed(let msg):
            return "HTML 读取失败: \(msg)"
        case .emptyDocument:
            return "HTML 文档为空"
        }
    }
}

/// Standalone HTML file → Markdown converter.
///
/// Strategy: `XHtmlToMarkdown` (streaming HTML tokenizer) first. If the resulting
/// markdown is suspiciously short (tokenizer bailed out on broken HTML), fall back
/// to `NSAttributedString(data:, documentType: .html)`.
struct HtmlConverter {
    func convert(url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw HtmlConverterError.readFailed(error.localizedDescription)
        }

        guard !data.isEmpty else {
            throw HtmlConverterError.emptyDocument
        }

        // Primary path: streaming tokenizer
        let md = (try? XHtmlToMarkdown.convert(data: data)) ?? ""
        let trimmed = md.trimmingCharacters(in: .whitespacesAndNewlines)

        // Sanity check: if tokenizer produced very little and the file is large,
        // fall back to NSAttributedString.
        if trimmed.count < 50 && data.count > 500 {
            return try nsAttributedFallback(data: data)
        }
        return md
    }

    private func nsAttributedFallback(data: Data) throws -> String {
        let attrString: NSAttributedString
        do {
            attrString = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
            )
        } catch {
            throw HtmlConverterError.readFailed(error.localizedDescription)
        }
        return AttributedStringToMarkdown.convert(attrString)
    }
}
