import Foundation
import AppKit

enum DocConverterError: LocalizedError {
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let msg):
            return "DOC 读取失败: \(msg)"
        }
    }
}

struct DocConverter {
    func convert(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        var docAttributes: NSDictionary?
        let attrString: NSAttributedString

        let ext = url.pathExtension.lowercased()
        if ext == "doc" {
            attrString = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.docFormat],
                documentAttributes: &docAttributes
            )
        } else {
            attrString = try NSAttributedString(
                data: data,
                options: [:],
                documentAttributes: &docAttributes
            )
        }

        return AttributedStringToMarkdown.convert(attrString)
    }
}
