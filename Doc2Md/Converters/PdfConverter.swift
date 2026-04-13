import Foundation
import PDFKit

enum PdfConverterError: LocalizedError {
    case cannotOpenPdf
    case noTextContent

    var errorDescription: String? {
        switch self {
        case .cannotOpenPdf:
            return "无法打开 PDF 文件"
        case .noTextContent:
            return "PDF 中未提取到文本内容"
        }
    }
}

struct PdfConverter {
    func convert(url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw PdfConverterError.cannotOpenPdf
        }

        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw PdfConverterError.noTextContent
        }

        var markdown = ""

        for i in 0..<pageCount {
            autoreleasepool {
                guard let page = document.page(at: i) else { return }
                guard let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

                let cleaned = cleanPageText(text)
                markdown += cleaned + "\n\n"

                if i < pageCount - 1 {
                    markdown += "---\n\n"
                }
            }
        }

        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PdfConverterError.noTextContent
        }

        return markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func cleanPageText(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")

        // Remove trailing whitespace per line
        lines = lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }

        // Collapse 3+ consecutive blank lines into 2
        var result: [String] = []
        var blankCount = 0
        for line in lines {
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

        return result.joined(separator: "\n")
    }
}
