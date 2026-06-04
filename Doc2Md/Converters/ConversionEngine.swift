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
            return "ZIP 中没有找到可转换的文档"
        case .zipPartialFailure(let errors):
            return "部分文件转换失败: \(errors.joined(separator: "; "))"
        }
    }
}

struct ConversionEngine {
    /// Set of file extensions the engine accepts (lower-cased).
    static let supportedExtensions: Set<String> = [
        // Office
        "docx", "doc", "pdf", "pptx", "ppt", "xlsx",
        // Rich text / markup
        "rtf", "html", "htm",
        // Plain text
        "txt", "md", "markdown",
        // OpenDocument
        "odt",
        // Ebook
        "epub", "mobi", "azw", "azw3",
        // Email
        "eml", "msg",
        // Image (OCR + EXIF)
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp",
        // Data / Notebook
        "csv", "tsv", "json", "xml", "ipynb",
        // Archive
        "zip",
    ]

    func convert(url: URL) throws -> [URL] {
        // Resolve via magic bytes — tolerant to renamed files where the
        // extension and the actual content disagree (e.g., `report` with no
        // extension, or a PDF saved as `notes.txt`). Falls back to the
        // original extension when magic detection is inconclusive.
        let ext = FileTypeDetector.resolve(url: url)

        switch ext {
        case "docx":
            // Image extraction: write embedded images to <basename>_assets/
            // beside the source file, then reference them by relative path
            // in the Markdown. Skipped in CLI string-output mode (see
            // convertToMarkdown below).
            let basename = url.deletingPathExtension().lastPathComponent
            let assetsName = "\(basename)_assets"
            let assetsDir = url.deletingLastPathComponent()
                .appendingPathComponent(assetsName)
            var conv = DocxConverter()
            conv.assetsDir = assetsDir
            conv.assetsRelativePrefix = assetsName
            let markdown = try conv.convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "doc":
            let markdown = try DocConverter().convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "pdf":
            return try convertPDF(url: url)

        case "pptx", "ppt":
            let markdown = try PptxConverter().convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "xlsx":
            let markdown = try XlsxConverter().convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "rtf":
            let markdown = try RtfConverter().convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "html", "htm":
            let markdown = try HtmlConverter().convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "txt", "md", "markdown":
            let markdown = try TextConverter().convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "odt":
            let markdown = try OdtConverter().convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "epub":
            return try convertEPUB(url: url)

        case "mobi", "azw", "azw3":
            let markdown = try MobiConverter().convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "eml":
            let markdown = try EmlConverter().convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "msg":
            let markdown = try MsgConverter().convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp":
            let markdown = try ImageConverter().convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "csv", "tsv":
            let markdown = try CsvConverter().convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "json":
            let markdown = try JsonConverter().convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "xml":
            let markdown = try XmlConverter().convert(url: url)
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case "ipynb":
            let markdown = try IpynbConverter().convert(url: url)
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

    // MARK: - String-output entry (for CLI stdout)
    //
    // Returns the converted Markdown as a String without writing to disk.
    // Only supports single-output converters. ZIP archives and PDF
    // structured-output modes are rejected (they produce multiple files,
    // which can't sensibly stream to stdout).

    func convertToMarkdown(url: URL) throws -> String {
        let ext = FileTypeDetector.resolve(url: url)

        switch ext {
        case "docx":    return try DocxConverter().convert(url: url)
        case "doc":     return try DocConverter().convert(url: url)
        case "pdf":     return try PdfConverter().convert(url: url)
        case "pptx", "ppt":
                        return try PptxConverter().convert(url: url)
        case "xlsx":    return try XlsxConverter().convert(url: url)
        case "rtf":     return try RtfConverter().convert(url: url)
        case "html", "htm":
                        return try HtmlConverter().convert(url: url)
        case "txt", "md", "markdown":
                        return try TextConverter().convert(url: url)
        case "odt":     return try OdtConverter().convert(url: url)
        case "epub":    return try EpubConverter().convert(url: url)
        case "mobi", "azw", "azw3":
                        return try MobiConverter().convert(url: url)
        case "eml":     return try EmlConverter().convert(url: url)
        case "msg":     return try MsgConverter().convert(url: url)
        case "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp":
                        return try ImageConverter().convert(url: url)
        case "csv", "tsv":
                        return try CsvConverter().convert(url: url)
        case "json":    return try JsonConverter().convert(url: url)
        case "xml":     return try XmlConverter().convert(url: url)
        case "ipynb":   return try IpynbConverter().convert(url: url)
        case "zip":
            throw ConversionError.unsupportedFormat(
                "ZIP produces multiple outputs; use file output mode instead of stdout")
        default:
            throw ConversionError.unsupportedFormat(ext)
        }
    }

    private func convertPDF(url: URL) throws -> [URL] {
        let converter = PdfConverter()
        let result = try converter.convertFull(url: url)
        var outputURLs: [URL] = []

        let pipeline = PipelineManager.shared.activeConfig

        if pipeline.isStepEnabled("structured_output") && result.wasOCR {
            // Structured output: write to a directory
            let pageTexts = result.pageData.map { (page: $0.pageNumber, text: $0.processedText) }
            let outputDir = try StructuredOutput.writeAll(
                fullMarkdown: result.markdown,
                rawText: result.rawText,
                pageTexts: pageTexts,
                qualityReport: result.qualityReport.generateReport(),
                sourceURL: url
            )
            outputURLs.append(outputDir.appendingPathComponent("full.md"))

            // Also save quality report
            try? result.qualityReport.saveReport(nextTo: outputDir.appendingPathComponent("full.md"))
        } else {
            // Simple single-file output
            let outputURL = try MarkdownWriter.write(markdown: result.markdown, nextTo: url)
            outputURLs.append(outputURL)

            // Save quality report if OCR was used
            if result.wasOCR && pipeline.isStepEnabled("quality_report") {
                try? result.qualityReport.saveReport(nextTo: outputURL)
            }
        }

        return outputURLs
    }

    // MARK: - EPUB

    private func convertEPUB(url: URL) throws -> [URL] {
        let settings = EpubSettings.shared
        let converter = EpubConverter()

        switch settings.outputMode {
        case .singleFile:
            let result = try converter.parse(url: url)
            let markdown = result.combinedMarkdown()
            let outputURL = try MarkdownWriter.write(markdown: markdown, nextTo: url)
            return [outputURL]

        case .perChapter:
            let result = try converter.parse(url: url)
            let bookDir = url.deletingLastPathComponent()
                .appendingPathComponent(result.bookTitle.replacingOccurrences(of: "/", with: "_"))

            try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)

            var outputURLs: [URL] = []

            // index.md
            var indexMd = "# \(result.bookTitle)\n\n"
            if !result.authors.isEmpty {
                indexMd += "**作者：** \(result.authors.joined(separator: ", "))\n\n"
            }
            if let lang = result.language, !lang.isEmpty {
                indexMd += "**语言：** \(lang)\n\n"
            }
            indexMd += "## 目录\n\n"

            for (i, chapter) in result.chapters.enumerated() {
                let idx = String(format: "%02d", i + 1)
                let safeTitle = (chapter.title ?? "chapter_\(idx)")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: ":", with: "_")
                    .prefix(60)
                let fileName = "\(idx)_\(safeTitle).md"
                let chapterURL = bookDir.appendingPathComponent(fileName)
                var chapterMd = ""
                if let t = chapter.title, !t.isEmpty {
                    chapterMd += "# \(t)\n\n"
                }
                chapterMd += chapter.markdown
                if !chapterMd.hasSuffix("\n") { chapterMd += "\n" }
                try chapterMd.write(to: chapterURL, atomically: true, encoding: .utf8)
                outputURLs.append(chapterURL)

                indexMd += "- [\(chapter.title ?? "Chapter \(i + 1)")](\(fileName))\n"
            }

            let indexURL = bookDir.appendingPathComponent("index.md")
            try indexMd.write(to: indexURL, atomically: true, encoding: .utf8)
            outputURLs.insert(indexURL, at: 0)

            return outputURLs
        }
    }
}
