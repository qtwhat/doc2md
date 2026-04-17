import Foundation
import AppKit

/// Shared utility that converts an `NSAttributedString` (from DOC / RTF / HTML
/// document types) into Markdown. Extracted from `DocConverter` so RtfConverter
/// and HtmlConverter can reuse the same heuristics.
struct AttributedStringToMarkdown {

    static func convert(_ attrString: NSAttributedString) -> String {
        let text = attrString.string
        guard !text.isEmpty else { return "" }

        let bodyFontSize = detectBodyFontSize(attrString)
        var markdown = ""

        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byParagraphs) { substring, range, _, _ in
            guard let paraText = substring else { return }
            let nsRange = NSRange(range, in: text)

            let (prefix, strippedText) = detectListAndStrip(paraText)
            let heading = detectHeading(attrString, range: nsRange, bodyFontSize: bodyFontSize)

            let formatted = formatInlineAttributes(attrString, range: nsRange, paragraphText: paraText)

            var line = heading + prefix
            if !prefix.isEmpty && !strippedText.isEmpty {
                let formattedStripped = formatInlineAttributes(
                    attrString,
                    range: nsRange,
                    paragraphText: paraText,
                    stripPrefix: paraText.count - strippedText.count
                )
                line += formattedStripped
            } else {
                line += formatted
            }

            markdown += line + "\n"
            if heading.isEmpty && prefix.isEmpty {
                markdown += "\n"
            } else if !heading.isEmpty {
                markdown += "\n"
            }
        }

        return cleanupMarkdown(markdown)
    }

    // MARK: - Font size detection

    private static func detectBodyFontSize(_ attrString: NSAttributedString) -> CGFloat {
        var fontSizeCounts: [CGFloat: Int] = [:]
        let fullRange = NSRange(location: 0, length: attrString.length)

        attrString.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let size = font.pointSize
            fontSizeCounts[size, default: 0] += range.length
        }

        return fontSizeCounts.max(by: { $0.value < $1.value })?.key ?? 12.0
    }

    // MARK: - Heading detection

    private static func detectHeading(_ attrString: NSAttributedString, range: NSRange, bodyFontSize: CGFloat) -> String {
        guard range.length > 0 else { return "" }

        var isBold = true
        var maxFontSize: CGFloat = 0
        var minFontSize: CGFloat = CGFloat.greatestFiniteMagnitude

        attrString.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
            guard let font = attrs[.font] as? NSFont else { return }
            let size = font.pointSize
            maxFontSize = max(maxFontSize, size)
            minFontSize = min(minFontSize, size)

            let traits = NSFontManager.shared.traits(of: font)
            if !traits.contains(.boldFontMask) {
                isBold = false
            }
        }

        guard isBold && maxFontSize > bodyFontSize * 1.1 else { return "" }
        guard (maxFontSize - minFontSize) < 2.0 else { return "" }

        let ratio = maxFontSize / bodyFontSize
        if ratio >= 1.8 { return "# " }
        if ratio >= 1.4 { return "## " }
        return "### "
    }

    // MARK: - List detection

    private static func detectListAndStrip(_ text: String) -> (String, String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("\u{2022}") || trimmed.hasPrefix("•") {
            let stripped = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            return ("- ", stripped)
        }
        if trimmed.hasPrefix("-") && trimmed.count > 1 && trimmed[trimmed.index(after: trimmed.startIndex)] == " " {
            let stripped = String(trimmed.dropFirst(2))
            return ("- ", stripped)
        }

        let pattern = #"^(\d+)[.)]\s+"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
            let numRange = Range(match.range(at: 1), in: trimmed)!
            let num = trimmed[numRange]
            let fullMatchRange = Range(match.range, in: trimmed)!
            let stripped = String(trimmed[fullMatchRange.upperBound...])
            return ("\(num). ", stripped)
        }

        return ("", text)
    }

    // MARK: - Inline formatting

    private static func formatInlineAttributes(_ attrString: NSAttributedString, range: NSRange, paragraphText: String, stripPrefix: Int = 0) -> String {
        var result = ""
        let effectiveStart = range.location + stripPrefix
        let effectiveLength = range.length - stripPrefix
        guard effectiveLength > 0 else { return "" }
        let effectiveRange = NSRange(location: effectiveStart, length: effectiveLength)

        attrString.enumerateAttributes(in: effectiveRange, options: []) { attrs, subRange, _ in
            let subText = (attrString.string as NSString).substring(with: subRange)
            guard !subText.isEmpty else { return }

            var formatted = subText

            if let link = attrs[.link] {
                let urlStr: String
                if let url = link as? URL {
                    urlStr = url.absoluteString
                } else if let str = link as? String {
                    urlStr = str
                } else {
                    urlStr = ""
                }
                if !urlStr.isEmpty {
                    formatted = "[\(formatted)](\(urlStr))"
                    result += formatted
                    return
                }
            }

            var isBold = false
            var isItalic = false
            if let font = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                isBold = traits.contains(.boldFontMask)
                isItalic = traits.contains(.italicFontMask)
            }

            if isBold && isItalic {
                formatted = "***\(formatted)***"
            } else if isBold {
                formatted = "**\(formatted)**"
            } else if isItalic {
                formatted = "*\(formatted)*"
            }

            result += formatted
        }

        return result
    }

    // MARK: - Cleanup

    private static func cleanupMarkdown(_ md: String) -> String {
        var result = md
        result = result.replacingOccurrences(of: "******", with: "")
        result = result.replacingOccurrences(of: "****", with: "")
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
