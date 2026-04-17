import Foundation
import PDFKit
import Vision
import AppKit

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

struct OCRPageData {
    let pageNumber: Int
    let rawText: String
    let processedText: String
    let observations: [VNRecognizedTextObservation]
}

struct PdfConversionResult {
    let markdown: String
    let rawText: String
    let pageData: [OCRPageData]
    let qualityReport: QualityReport
    let wasOCR: Bool
}

struct PdfConverter {

    func convert(url: URL) throws -> String {
        let result = try convertFull(url: url)
        return result.markdown
    }

    func convertFull(url: URL) throws -> PdfConversionResult {
        guard let document = PDFDocument(url: url) else {
            throw PdfConverterError.cannotOpenPdf
        }

        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw PdfConverterError.noTextContent
        }

        // First try PDFKit text extraction
        var pdfKitText = ""
        var hasText = false

        for i in 0..<pageCount {
            autoreleasepool {
                guard let page = document.page(at: i) else { return }
                guard let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                hasText = true
                pdfKitText += text + "\n\n---\n\n"
            }
        }

        if hasText {
            let report = QualityReport(fileName: url.lastPathComponent)
            let cleaned = PostProcessor(settings: OCRSettings.shared).process(pdfKitText)
            return PdfConversionResult(
                markdown: cleaned.trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
                rawText: pdfKitText,
                pageData: [],
                qualityReport: report,
                wasOCR: false
            )
        }

        // Fallback: OCR via Vision framework
        return try ocrExtract(document: document, pageCount: pageCount, sourceURL: url)
    }

    // MARK: - OCR Pipeline

    private func ocrExtract(document: PDFDocument, pageCount: Int, sourceURL: URL) throws -> PdfConversionResult {
        let settings = OCRSettings.shared
        let pipeline = PipelineManager.shared.activeConfig
        let postProcessor = PostProcessor(settings: settings)
        let corrections = ExternalCorrections.shared
        let report = QualityReport(fileName: sourceURL.lastPathComponent)

        var allPageData: [OCRPageData] = []
        var markdown = ""
        var rawTextAll = ""

        for i in 0..<pageCount {
            try autoreleasepool {
                guard let page = document.page(at: i) else { return }

                let pageRect = page.bounds(for: .mediaBox)
                let scale: CGFloat = CGFloat(settings.renderScale.rawValue)
                let width = Int(pageRect.width * scale)
                let height = Int(pageRect.height * scale)

                guard let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                ) else { return }

                context.setFillColor(NSColor.white.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: context)

                guard let cgImage = context.makeImage() else { return }

                // OCR with Vision
                let isCoverPage = (i == 0)
                let (observations, rawText) = try recognizeTextWithObservations(
                    in: cgImage,
                    isCoverPage: isCoverPage && pipeline.isStepEnabled("column_reconstruction")
                )

                guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

                rawTextAll += "## Page \(i + 1)\n\n\(rawText)\n\n"

                // Post-processing pipeline
                var processed = rawText

                // Step: Full post-processing (punctuation, special chars, hyphen merge, noise removal)
                processed = postProcessor.process(processed)

                // Step: Paragraph bracket fixing (always applied for OCR text)
                processed = fixParagraphBrackets(processed)

                // Step: Dictionary correction
                if pipeline.isStepEnabled("dictionary_correct") && settings.enableOCRCorrection {
                    let beforeCorrection = processed
                    processed = corrections.applyCorrections(to: processed)
                    trackCorrections(before: beforeCorrection, after: processed, report: report)
                }

                // Step: Quality analysis
                if pipeline.isStepEnabled("quality_report") {
                    report.analyzeText(processed, page: i + 1, observations: observations)
                }

                let pageData = OCRPageData(
                    pageNumber: i + 1,
                    rawText: rawText,
                    processedText: processed,
                    observations: observations
                )
                allPageData.append(pageData)

                markdown += "## Page \(i + 1)\n\n"
                markdown += processed + "\n\n"
            }
        }

        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PdfConverterError.noTextContent
        }

        let finalMarkdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"

        // Step: Structured output
        if pipeline.isStepEnabled("structured_output") {
            let pageTexts = allPageData.map { (page: $0.pageNumber, text: $0.processedText) }
            _ = try? StructuredOutput.writeAll(
                fullMarkdown: finalMarkdown,
                rawText: rawTextAll,
                pageTexts: pageTexts,
                qualityReport: report.generateReport(),
                sourceURL: sourceURL
            )
        }

        return PdfConversionResult(
            markdown: finalMarkdown,
            rawText: rawTextAll,
            pageData: allPageData,
            qualityReport: report,
            wasOCR: true
        )
    }

    // MARK: - OCR with Observation Tracking

    private func recognizeTextWithObservations(
        in image: CGImage,
        isCoverPage: Bool
    ) throws -> ([VNRecognizedTextObservation], String) {
        var observations: [VNRecognizedTextObservation] = []
        var ocrError: Error?

        let request = VNRecognizeTextRequest { req, error in
            if let error = error {
                ocrError = error
                return
            }
            observations = req.results as? [VNRecognizedTextObservation] ?? []
        }

        request.recognitionLevel = .accurate
        request.recognitionLanguages = OCRSettings.shared.recognitionLanguages
        request.usesLanguageCorrection = true

        if #available(macOS 14.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
        }

        var hints = ocrHintWords
        hints.append(contentsOf: ExternalCorrections.shared.customHintWords)
        request.customWords = hints

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        if let error = ocrError {
            throw error
        }

        // Text reconstruction strategy:
        // - Cover page: use column-aware reconstruction to handle multi-column layouts
        // - All other pages: use SIMPLE top-to-bottom ordering (preserves Vision's original order)
        //   This avoids content loss from spatial re-grouping artifacts
        let text: String
        if isCoverPage {
            text = ColumnReconstructor.reconstruct(observations: observations, forceColumns: true)
        } else {
            text = simpleTextFromObservations(observations)
        }

        return (observations, text)
    }

    /// Simple text extraction: sort observations top-to-bottom, left-to-right for same line.
    /// This preserves the natural reading order without any column detection or line merging
    /// that could cause content loss.
    private func simpleTextFromObservations(_ observations: [VNRecognizedTextObservation]) -> String {
        let sorted = observations.sorted { a, b in
            let ay = a.boundingBox.origin.y
            let by = b.boundingBox.origin.y
            // If Y positions are close (within 0.8% of image height), sort by X
            if abs(ay - by) < 0.008 {
                return a.boundingBox.origin.x < b.boundingBox.origin.x
            }
            return ay > by  // Higher Y = higher on page in Vision coords
        }

        let lines = sorted.compactMap { obs -> String? in
            guard let top = obs.topCandidates(1).first else { return nil }
            return top.string
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Paragraph Bracket Fixing

    /// Fix common OCR errors in paragraph numbers: [0001], [0002], etc.
    /// Vision often misreads ] as 1, ), |, or drops it entirely.
    /// Also fixes ( being read as [ in paragraph markers.
    private func fixParagraphBrackets(_ text: String) -> String {
        var result = text

        // Fix right bracket: [NNNN1 → [NNNN], [NNNN) → [NNNN], [NNNN| → [NNNN]
        // Pattern: [ + 4 digits + non-] closing char
        result = result.replacingOccurrences(
            of: #"\[(\d{4})[1)\|]"#,
            with: "[$1]",
            options: .regularExpression
        )

        // Fix missing right bracket: [NNNN followed by space or newline (no closing bracket at all)
        result = result.replacingOccurrences(
            of: #"\[(\d{4})(?=\s)"#,
            with: "[$1]",
            options: .regularExpression
        )

        // Fix left bracket: (NNNN] → [NNNN]
        result = result.replacingOccurrences(
            of: #"\((\d{4})\]"#,
            with: "[$1]",
            options: .regularExpression
        )

        // Fix both brackets wrong: (NNNN) when it's clearly a paragraph number
        // Only at start of line or after whitespace, to avoid false positives with actual parenthetical numbers
        result = result.replacingOccurrences(
            of: #"(?:^|\n)\((\d{4})\)"#,
            with: "\n[$1]",
            options: .regularExpression
        )

        return result
    }

    // MARK: - Correction Tracking

    private func trackCorrections(before: String, after: String, report: QualityReport) {
        let beforeWords = before.components(separatedBy: .whitespacesAndNewlines)
        let afterWords = after.components(separatedBy: .whitespacesAndNewlines)

        if beforeWords.count == afterWords.count {
            for (b, a) in zip(beforeWords, afterWords) where b != a {
                report.recordCorrection(original: b, corrected: a)
            }
        }
    }

    // MARK: - OCR Hint Words

    private var ocrHintWords: [String] {
        [
            "RRC", "RRC_CONNECTED", "RRC_IDLE", "RRC_INACTIVE",
            "UE", "gNB", "eNB", "NR", "LTE", "E-UTRA", "NG-RAN",
            "PDCP", "RLC", "MAC", "SDAP", "NAS", "AS",
            "SRB", "DRB", "SRB0", "SRB1", "SRB2",
            "MIB", "SIB", "SIB1", "BCCH", "CCCH", "DCCH", "DTCH",
            "HARQ", "DRX", "BWP", "SSB", "CORESET", "PDCCH", "PDSCH", "PUSCH", "PUCCH",
            "SDT", "RNA", "RAN", "CN", "AMF", "SMF", "UPF",
            "QoS", "QCI", "APN", "DNN", "S-NSSAI", "PLMN",
            "I-RNTI", "C-RNTI", "SI-RNTI",
            "RRCSetup", "RRCResume", "RRCRelease", "RRCReconfiguration",
            "RRCReestablishment", "RRCReject", "RRCSetupComplete",
            "Xn", "NG", "F1", "E1", "X2", "S1",
            "PTM", "PTP", "MBMS", "MBS",
            "embodiment", "embodiments", "comprises", "comprising",
            "thereof", "wherein", "herein", "apparatus", "method",
            "transceiver", "processor", "non-transitory",
            "claim", "claims", "FIG", "FIGS",
            "e.g.", "i.e.", "etc.", "IoT",
            "Shenzhen", "Guangdong", "China",
            "International", "Patent", "Application", "Publication",
        ]
    }
}
