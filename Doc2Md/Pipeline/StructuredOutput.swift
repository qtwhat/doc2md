import Foundation

struct ParagraphEntry: Codable {
    let paraId: String
    let page: Int
    let text: String
}

struct PatentMetadata: Codable {
    var internationalAppNumber: String?
    var filingDate: String?
    var publicationDate: String?
    var applicant: String?
    var inventors: [String]?
    var title: String?
    var ipcClassification: [String]?
    var priorityDate: String?
    var designatedStates: String?
}

struct StructuredOutput {

    /// Write all structured outputs for a PDF OCR result
    /// - Parameters:
    ///   - fullMarkdown: the complete post-processed markdown
    ///   - rawText: raw OCR text before post-processing
    ///   - pageTexts: array of (pageNumber, text) tuples
    ///   - qualityReport: the quality report string
    ///   - sourceURL: original PDF file URL
    /// - Returns: URL of the output directory
    @discardableResult
    static func writeAll(
        fullMarkdown: String,
        rawText: String,
        pageTexts: [(page: Int, text: String)],
        qualityReport: String,
        sourceURL: URL
    ) throws -> URL {
        // Create output directory next to source file
        let dirName = sourceURL.deletingPathExtension().lastPathComponent
        let outputDir = sourceURL.deletingLastPathComponent().appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // 1. full.md
        try fullMarkdown.write(
            to: outputDir.appendingPathComponent("full.md"),
            atomically: true, encoding: .utf8
        )

        // 2. claims.md
        let claims = extractClaims(from: fullMarkdown)
        if !claims.isEmpty {
            try claims.write(
                to: outputDir.appendingPathComponent("claims.md"),
                atomically: true, encoding: .utf8
            )
        }

        // 3. paragraphs.jsonl
        let paragraphs = extractParagraphs(from: pageTexts)
        let encoder = JSONEncoder()
        let jsonlLines = paragraphs.compactMap { entry -> String? in
            guard let data = try? encoder.encode(entry) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        try jsonlLines.joined(separator: "\n").write(
            to: outputDir.appendingPathComponent("paragraphs.jsonl"),
            atomically: true, encoding: .utf8
        )

        // 4. metadata.json
        let metadata = extractMetadata(from: pageTexts)
        let metaData = try JSONEncoder().encode(metadata)
        let metaJSON = try JSONSerialization.jsonObject(with: metaData)
        let prettyData = try JSONSerialization.data(
            withJSONObject: metaJSON,
            options: [.prettyPrinted, .sortedKeys]
        )
        try prettyData.write(to: outputDir.appendingPathComponent("metadata.json"))

        // 5. raw_ocr.txt
        try rawText.write(
            to: outputDir.appendingPathComponent("raw_ocr.txt"),
            atomically: true, encoding: .utf8
        )

        // 6. quality_report.txt
        try qualityReport.write(
            to: outputDir.appendingPathComponent("quality_report.txt"),
            atomically: true, encoding: .utf8
        )

        return outputDir
    }

    // MARK: - Claims Extraction

    /// Extract patent claims section from the full markdown text.
    ///
    /// Looks for headings like "Claims", "CLAIMS", "What is claimed", then captures
    /// everything until the next major section heading (Abstract, Description,
    /// Drawings) or end of document.
    static func extractClaims(from markdown: String) -> String {
        // Pattern: match a claims heading line, then capture everything after it
        // The heading may be a markdown heading (# Claims) or standalone line
        let claimsStartPatterns = [
            #"(?mi)^#{1,3}\s*claims\s*$"#,
            #"(?mi)^claims\s*$"#,
            #"(?mi)^what\s+is\s+claimed\s+is\s*:?\s*$"#,
            #"(?mi)^what\s+is\s+claimed\s*:?\s*$"#,
            #"(?mi)^the\s+claims?\s*:?\s*$"#,
        ]

        var claimsStartRange: Range<String.Index>? = nil

        for pattern in claimsStartPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(
                   in: markdown,
                   range: NSRange(markdown.startIndex..., in: markdown)
               ),
               let range = Range(match.range, in: markdown)
            {
                // Pick the earliest match if multiple patterns hit
                if claimsStartRange == nil || range.lowerBound < claimsStartRange!.lowerBound {
                    claimsStartRange = range
                }
            }
        }

        guard let startRange = claimsStartRange else {
            // Fallback: look for the first numbered claim pattern "1." preceded by blank line
            // This handles cases where there's no explicit heading
            let numberedClaimPattern = #"(?m)(?:^|\n\n)(1\.\s+(?:A\s|An\s|The\s))"#
            guard let regex = try? NSRegularExpression(pattern: numberedClaimPattern),
                  let match = regex.firstMatch(
                      in: markdown,
                      range: NSRange(markdown.startIndex..., in: markdown)
                  ),
                  let range = Range(match.range(at: 1), in: markdown)
            else {
                return ""
            }
            let textFromClaim1 = String(markdown[range.lowerBound...])
            return trimClaimsEnd(textFromClaim1)
        }

        // Extract from the heading line onward
        let textFromHeading = String(markdown[startRange.lowerBound...])
        return trimClaimsEnd(textFromHeading)
    }

    /// Trim the claims text at the next major section boundary.
    private static func trimClaimsEnd(_ text: String) -> String {
        // Stop at next major section: Abstract, Description, Drawings, Figures,
        // or a markdown heading that is clearly not a claim
        let endPatterns = [
            #"(?mi)^#{1,3}\s*abstract\s*$"#,
            #"(?mi)^abstract\s*$"#,
            #"(?mi)^#{1,3}\s*description\s*$"#,
            #"(?mi)^#{1,3}\s*(?:brief\s+)?description\s+of\s+(?:the\s+)?drawings?\s*$"#,
            #"(?mi)^#{1,3}\s*drawings?\s*$"#,
            #"(?mi)^#{1,3}\s*figures?\s*$"#,
            #"(?mi)^#{1,3}\s*(?:detailed\s+)?description\s*$"#,
        ]

        var earliestEnd: String.Index = text.endIndex

        for pattern in endPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(
                   in: text,
                   range: NSRange(text.startIndex..., in: text)
               ),
               let range = Range(match.range, in: text)
            {
                // Skip if this match is at the very start (could be the claims heading itself)
                if range.lowerBound > text.startIndex && range.lowerBound < earliestEnd {
                    earliestEnd = range.lowerBound
                }
            }
        }

        return String(text[text.startIndex..<earliestEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Paragraph Extraction

    /// Extract paragraphs marked with `[NNNN]` markers across pages.
    ///
    /// Patent texts use markers like [0001], [0002], etc. Each marker starts a new
    /// paragraph. We track which page each paragraph appears on.
    static func extractParagraphs(from pageTexts: [(page: Int, text: String)]) -> [ParagraphEntry] {
        var entries: [ParagraphEntry] = []

        // Pattern: [0001], [0002], ... up to [9999]
        let markerPattern = #"\[(\d{4})\]"#
        guard let markerRegex = try? NSRegularExpression(pattern: markerPattern) else {
            return entries
        }

        for (page, text) in pageTexts {
            let nsText = text as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)
            let matches = markerRegex.matches(in: text, range: fullRange)

            for (i, match) in matches.enumerated() {
                guard let idRange = Range(match.range(at: 1), in: text) else { continue }
                let paraId = String(text[idRange])

                // Text starts after the marker (after the closing "]")
                guard let markerRange = Range(match.range, in: text) else { continue }
                let textStart = markerRange.upperBound

                // Text ends at the next marker or end of page text
                let textEnd: String.Index
                if i + 1 < matches.count,
                   let nextRange = Range(matches[i + 1].range, in: text)
                {
                    textEnd = nextRange.lowerBound
                } else {
                    textEnd = text.endIndex
                }

                let paragraphText = String(text[textStart..<textEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if !paragraphText.isEmpty {
                    entries.append(ParagraphEntry(
                        paraId: paraId,
                        page: page,
                        text: paragraphText
                    ))
                }
            }
        }

        return entries
    }

    // MARK: - Metadata Extraction

    /// Extract patent cover page metadata from the first pages of OCR text.
    ///
    /// WIPO/PCT cover pages use INID codes like (11), (22), (43), (51), (54), (71), (72).
    /// OCR quality varies, so patterns are lenient.
    static func extractMetadata(from pageTexts: [(page: Int, text: String)]) -> PatentMetadata {
        // Use first 2 pages (cover page info)
        let coverText = pageTexts.prefix(2).map(\.text).joined(separator: "\n")
        var meta = PatentMetadata()

        // International Application Number: PCT/XX20XX/NNNNNN or WO 20XX/NNNNNN
        meta.internationalAppNumber = firstMatch(
            in: coverText,
            pattern: #"(?i)(?:PCT/[A-Z]{2}\d{4}/\d{4,6}|WO\s*\d{4}/\d{4,6})"#
        )

        // Filing date — near (22) label
        meta.filingDate = extractINIDField(from: coverText, code: "22", dateOnly: true)

        // Publication date — near (43) label
        meta.publicationDate = extractINIDField(from: coverText, code: "43", dateOnly: true)

        // Applicant — near (71) label
        meta.applicant = extractINIDField(from: coverText, code: "71")

        // Inventors — near (72) label, may be multiple names
        if let inventorText = extractINIDField(from: coverText, code: "72") {
            meta.inventors = parseInventors(inventorText)
        }

        // Title — near (54) label
        meta.title = extractINIDField(from: coverText, code: "54")

        // IPC classification — near (51) label
        if let ipcText = extractINIDField(from: coverText, code: "51") {
            meta.ipcClassification = parseIPCCodes(ipcText)
        }

        // Priority date — near (30) or (31)/(32) labels
        meta.priorityDate = extractINIDField(from: coverText, code: "32", dateOnly: true)
            ?? extractINIDField(from: coverText, code: "30", dateOnly: true)

        // Designated states — near (81) label
        meta.designatedStates = extractINIDField(from: coverText, code: "81")

        return meta
    }

    // MARK: - Private Helpers

    /// Extract text associated with an INID code like (22), (43), etc.
    ///
    /// Looks for patterns like:
    /// - `(22) 15 March 2024`
    /// - `(22) International Filing Date: 15.03.2024`
    /// - `( 22 ) 2024-03-15`
    private static func extractINIDField(
        from text: String,
        code: String,
        dateOnly: Bool = false
    ) -> String? {
        // Match the INID code with optional spaces inside parens, then capture text after it
        // Allow for OCR artifacts: spaces inside parens, colon or newline after code
        let pattern = #"\(\s*"# + code + #"\s*\)\s*[:\-]?\s*([^\n\(]{2,120})"#
        guard let value = firstMatch(in: text, pattern: pattern, group: 1) else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        if dateOnly {
            // Try to find a date within the captured text
            return extractDate(from: trimmed) ?? trimmed
        }

        // Strip common label prefixes
        let labelPrefixes = [
            "International Filing Date",
            "International Publication Date",
            "Publication Date",
            "Filing Date",
            "Applicant",
            "Applicants",
            "Inventor",
            "Inventors",
            "Title",
            "Designated States",
        ]
        var cleaned = trimmed
        for prefix in labelPrefixes {
            if let range = cleaned.range(of: prefix, options: .caseInsensitive) {
                cleaned = String(cleaned[range.upperBound...])
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":;")))
            }
        }

        return cleaned.isEmpty ? trimmed : cleaned
    }

    /// Try to extract a date string from text (various formats).
    private static func extractDate(from text: String) -> String? {
        let datePatterns = [
            // ISO: 2024-03-15
            #"\d{4}-\d{2}-\d{2}"#,
            // Dotted: 15.03.2024 or 2024.03.15
            #"\d{1,2}\.\d{2}\.\d{4}"#,
            #"\d{4}\.\d{2}\.\d{2}"#,
            // Slashed: 15/03/2024
            #"\d{1,2}/\d{2}/\d{4}"#,
            // Written: 15 March 2024, March 15, 2024
            #"\d{1,2}\s+(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{4}"#,
            #"(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},?\s+\d{4}"#,
        ]

        for pattern in datePatterns {
            if let match = firstMatch(in: text, pattern: pattern) {
                return match
            }
        }
        return nil
    }

    /// Parse inventor names from a block of text.
    ///
    /// Inventors may be separated by semicolons, commas (when followed by first name),
    /// or newlines. Handles formats like "SMITH, John; DOE, Jane" or "John Smith, Jane Doe".
    private static func parseInventors(_ text: String) -> [String] {
        // Try semicolon-separated first (most reliable)
        let bySemicolon = text.components(separatedBy: ";").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        if bySemicolon.count > 1 {
            return bySemicolon
        }

        // Try newline-separated
        let byNewline = text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty && $0.count > 2 }

        if byNewline.count > 1 {
            return byNewline
        }

        // Single inventor or comma-separated
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return [trimmed]
        }
        return []
    }

    /// Parse IPC classification codes from text.
    ///
    /// IPC codes follow patterns like H04W 36/00, H04L 5/00, G06F 15/16.
    private static func parseIPCCodes(_ text: String) -> [String] {
        let pattern = #"[A-H]\d{2}[A-Z]\s*\d{1,4}/\d{2,4}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        var codes: [String] = []
        for match in matches {
            if let range = Range(match.range, in: text) {
                let code = String(text[range]).trimmingCharacters(in: .whitespaces)
                if !codes.contains(code) {
                    codes.append(code)
                }
            }
        }

        // If regex found nothing, return the whole text as a single entry (OCR may have mangled it)
        if codes.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return [trimmed]
            }
        }

        return codes
    }

    /// Return the first regex match (or a specific capture group) from text.
    private static func firstMatch(
        in text: String,
        pattern: String,
        group: Int = 0
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              group < match.numberOfRanges,
              let range = Range(match.range(at: group), in: text)
        else {
            return nil
        }
        return String(text[range])
    }
}
