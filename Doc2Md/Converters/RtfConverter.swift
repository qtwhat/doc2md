import Foundation
import AppKit

enum RtfConverterError: LocalizedError {
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let msg):
            return "RTF 读取失败: \(msg)"
        }
    }
}

/// RTF → Markdown via `NSAttributedString(documentType: .rtf)`.
/// Uses the shared `AttributedStringToMarkdown` utility.
struct RtfConverter {
    func convert(url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RtfConverterError.readFailed(error.localizedDescription)
        }

        let attrString: NSAttributedString
        do {
            attrString = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
        } catch {
            throw RtfConverterError.readFailed(error.localizedDescription)
        }

        return AttributedStringToMarkdown.convert(attrString)
    }
}
