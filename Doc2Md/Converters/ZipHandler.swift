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
            guard ConversionEngine.supportedExtensions.contains(ext),
                  ext != "zip"  // don't recurse into nested zips from here
            else { continue }

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
                case "xlsx":
                    markdown = try XlsxConverter().convert(url: fileURL)
                case "rtf":
                    markdown = try RtfConverter().convert(url: fileURL)
                case "html", "htm":
                    markdown = try HtmlConverter().convert(url: fileURL)
                case "txt", "md", "markdown":
                    markdown = try TextConverter().convert(url: fileURL)
                case "odt":
                    markdown = try OdtConverter().convert(url: fileURL)
                case "epub":
                    // Force single-file mode inside zip batch
                    markdown = try EpubConverter().convert(url: fileURL)
                case "mobi", "azw", "azw3":
                    markdown = try MobiConverter().convert(url: fileURL)
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
