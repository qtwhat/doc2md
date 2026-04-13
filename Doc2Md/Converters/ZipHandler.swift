import Foundation

struct ZipHandler {
    func processZip(url: URL) throws -> [URL] {
        let tempDir = try ZipExtractor.extract(url: url)
        defer { ZipExtractor.cleanup(tempDir: tempDir) }

        let parentDir = url.deletingLastPathComponent()
        var outputURLs: [URL] = []
        var errors: [String] = []

        let enumerator = FileManager.default.enumerator(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            guard ["docx", "doc", "pdf", "pptx", "ppt"].contains(ext) else { continue }

            do {
                let markdown: String
                switch ext {
                case "docx":
                    markdown = try DocxConverter().convert(url: fileURL)
                case "doc":
                    markdown = try DocConverter().convert(url: fileURL)
                case "pdf":
                    markdown = try PdfConverter().convert(url: fileURL)
                case "pptx", "ppt":
                    markdown = try PptxConverter().convert(url: fileURL)
                default:
                    continue
                }

                let outputURL = try MarkdownWriter.write(
                    markdown: markdown,
                    nextTo: parentDir.appendingPathComponent(fileURL.lastPathComponent)
                )
                outputURLs.append(outputURL)
            } catch {
                errors.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if outputURLs.isEmpty && !errors.isEmpty {
            throw ConversionError.zipPartialFailure(errors)
        }

        return outputURLs
    }
}
