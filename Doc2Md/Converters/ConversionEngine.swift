import Foundation

enum ConversionError: LocalizedError {
    case unsupportedFormat(String)
    case noDocumentsInZip
    case zipPartialFailure([String])

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "不支持的文件格式: .\(ext)"
        case .noDocumentsInZip:
            return "ZIP 中没有找到 .docx 或 .doc 文件"
        case .zipPartialFailure(let errors):
            return "部分文件转换失败: \(errors.joined(separator: "; "))"
        }
    }
}

struct ConversionEngine {
    func convert(url: URL) throws -> [URL] {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "docx":
            let markdown = try DocxConverter().convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "doc":
            let markdown = try DocConverter().convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "pdf":
            let markdown = try PdfConverter().convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "pptx", "ppt":
            let markdown = try PptxConverter().convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "zip":
            let outputURLs = try ZipHandler().processZip(url: url)
            if outputURLs.isEmpty {
                throw ConversionError.noDocumentsInZip
            }
            return outputURLs

        default:
            throw ConversionError.unsupportedFormat(ext)
        }
    }
}
