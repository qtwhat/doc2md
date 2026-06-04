import Foundation
import Vision
import AppKit
import ImageIO
import CoreGraphics

// MARK: - Errors

enum ImageConverterError: LocalizedError {
    case cannotOpenImage
    case noTextContent

    var errorDescription: String? {
        switch self {
        case .cannotOpenImage:  return "无法打开图片文件"
        case .noTextContent:    return "图片中未识别到文本"
        }
    }
}

// MARK: - Converter
//
// Image → Markdown via Vision OCR.
//
// Reuses the same Vision pipeline as PdfConverter (recognition languages,
// custom hint words, post-processing, external correction dictionary,
// paragraph-bracket fixing). The only difference: no page rasterization —
// the image already has pixels we can hand to Vision.
//
// Render-scale handling:
//   * For small images (< 1500px on the long edge), we upscale by the user's
//     configured OCR render scale (2x/3x/4x). Vision benefits from larger
//     glyph rasters for fine print.
//   * For images already at high resolution we leave them alone — upscaling
//     past Vision's effective resolution wastes memory without helping.
//
// EXIF orientation is honored — iPhone photos and scanned documents
// frequently have non-default orientation.

struct ImageConverter {

    /// Extensions handled by this converter (lower-cased).
    static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif",
        "tiff", "tif", "bmp", "gif", "webp",
    ]

    func convert(url: URL) throws -> String {
        guard let cgImage = loadImage(at: url) else {
            throw ImageConverterError.cannotOpenImage
        }

        let settings = OCRSettings.shared
        let pipeline = PipelineManager.shared.activeConfig
        let postProcessor = PostProcessor(settings: settings)
        let corrections = ExternalCorrections.shared

        // EXIF / image metadata block (independent of OCR — useful for archival
        // even if Vision finds no text).
        let metadata = MetadataExtractor.extractImageMetadata(url: url)

        // Upscale only if the source is small. Threshold chosen empirically:
        // Vision text recognition starts losing accuracy when glyphs are
        // smaller than ~12px tall in the input raster.
        let prepared = upscaleIfNeeded(cgImage,
                                       scale: CGFloat(settings.renderScale.rawValue))

        let (observations, rawText) = try recognize(prepared)

        // Build output: title + metadata block + OCR text.
        // If OCR finds nothing but metadata is present, still emit the metadata
        // (the file is at least documented). If both are empty, throw.
        let hasText = !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasText && metadata.isEmpty {
            throw ImageConverterError.noTextContent
        }

        let title = url.deletingPathExtension().lastPathComponent
        var markdown = "# \(title)\n\n"

        if !metadata.isEmpty {
            markdown += MetadataExtractor.renderAsMarkdownTable(metadata) + "\n"
        }

        if hasText {
            var processed = postProcessor.process(rawText)
            processed = fixParagraphBrackets(processed)
            if pipeline.isStepEnabled("dictionary_correct") && settings.enableOCRCorrection {
                processed = corrections.applyCorrections(to: processed)
            }
            if !metadata.isEmpty { markdown += "---\n\n" }
            markdown += processed
        }

        if !markdown.hasSuffix("\n") { markdown += "\n" }
        _ = observations  // reserved for future quality reporting
        return markdown
    }

    // MARK: - Image Loading

    private func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        // Honor EXIF orientation. Without this, rotated phone photos OCR poorly.
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        if orientation == 1 { return cg }
        return reorient(cg, orientationRaw: orientation) ?? cg
    }

    /// Apply CGImagePropertyOrientation (1..8) by drawing into a transformed context.
    private func reorient(_ image: CGImage, orientationRaw: UInt32) -> CGImage? {
        guard let ori = CGImagePropertyOrientation(rawValue: orientationRaw) else { return nil }
        let nsImg = NSImage(cgImage: image, size: .zero)
        let rep = NSBitmapImageRep(data: nsImg.tiffRepresentation ?? Data())
        // Fall back to CIImage path — simpler than hand-rolling a transform matrix.
        guard let ci = CIImage(cgImage: image).oriented(ori) as CIImage?,
              let ctx = CIContext().createCGImage(ci, from: ci.extent) else {
            _ = rep
            return nil
        }
        return ctx
    }

    // MARK: - Upscale

    private func upscaleIfNeeded(_ image: CGImage, scale: CGFloat) -> CGImage {
        let longEdge = max(image.width, image.height)
        guard longEdge < 1500, scale > 1.0 else { return image }

        let w = Int(CGFloat(image.width) * scale)
        let h = Int(CGFloat(image.height) * scale)
        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return image }

        ctx.interpolationQuality = .high
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    // MARK: - Vision OCR

    private func recognize(_ image: CGImage) throws -> ([VNRecognizedTextObservation], String) {
        var observations: [VNRecognizedTextObservation] = []
        var ocrError: Error?

        let request = VNRecognizeTextRequest { req, error in
            if let error = error { ocrError = error; return }
            observations = req.results as? [VNRecognizedTextObservation] ?? []
        }
        request.recognitionLevel = .accurate
        // Language selection: prefer Vision's auto-detection (handles
        // CJK-dominant images correctly even with English as the user's
        // primary). Manual order applies only when the user explicitly
        // disables auto-detect in Settings.
        if OCRSettings.shared.automaticallyDetectsLanguage {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = OCRSettings.shared.recognitionLanguages
        }
        request.usesLanguageCorrection = true
        if #available(macOS 14.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
        }
        // Custom-word hints from the correction dictionary improve recall on
        // domain-specific tokens (acronyms, product names, etc.).
        request.customWords = ExternalCorrections.shared.customHintWords

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        if let error = ocrError { throw error }

        // 1. Detect tables (grids of aligned text blocks). Extract as
        //    Markdown table blocks; remove their observations from the
        //    flow text below.
        // 2. Sort remaining observations top-to-bottom, left-to-right.
        // 3. Concatenate flow text + table markdown.
        let tables = TableDetector.detect(observations: observations)
        let tableIndices = Set(tables.flatMap { $0.observationIndices })
        let flowObs = observations.enumerated()
            .filter { !tableIndices.contains($0.offset) }
            .map(\.element)
        let sorted = flowObs.sorted { a, b in
            let ay = a.boundingBox.origin.y
            let by = b.boundingBox.origin.y
            if abs(ay - by) < 0.008 {
                return a.boundingBox.origin.x < b.boundingBox.origin.x
            }
            return ay > by
        }
        var text = sorted.compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
        for t in tables {
            text += "\n\n" + t.markdown
        }
        return (observations, text)
    }

    // MARK: - Paragraph Bracket Fixing
    //
    // Same as PdfConverter: Vision often misreads "]" in paragraph markers
    // like [0001] as "1", ")", "|", or drops it entirely.

    private func fixParagraphBrackets(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: #"\[(\d{4})[1)\|]"#, with: "[$1]", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\[(\d{4})(?=\s)"#, with: "[$1]", options: .regularExpression)
        return result
    }
}
