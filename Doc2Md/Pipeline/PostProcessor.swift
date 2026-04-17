import Foundation

struct PostProcessor {
    let settings: OCRSettings

    // MARK: - Compound words that should NOT be merged across lines

    /// Default list of hyphenated compound words to preserve (not merge).
    /// These are common 3GPP / technical terms where the hyphen is meaningful.
    static let defaultPreserveList: Set<String> = [
        "point-to-multipoint",
        "UE-specific",
        "non-transitory",
        "semi-static",
        "half-duplex",
        "full-duplex",
        "re-establishment",
        "pre-configured",
        "multi-carrier",
        "single-carrier",
        "intra-frequency",
        "inter-frequency",
        "intra-cell",
        "inter-cell",
        "co-located",
        "per-UE",
        "per-cell",
        "end-to-end",
        "over-the-air",
    ]

    /// Lazily-loaded preserve list: default set merged with any external file entries.
    private var preserveList: Set<String> {
        var list = Self.defaultPreserveList
        if let external = Self.loadExternalPreserveList() {
            list.formUnion(external)
        }
        return list
    }

    /// Build a set of lowercased prefixes from the preserve list so we can quickly
    /// check whether a hyphenated line-break should be kept.
    /// e.g. "point-to-multipoint" contributes prefixes "point", "point-to".
    private var preservePrefixes: Set<String> {
        var prefixes = Set<String>()
        for word in preserveList {
            let parts = word.lowercased().components(separatedBy: "-")
            var running = ""
            for (i, part) in parts.enumerated() {
                if i > 0 { running += "-" }
                running += part
                if i < parts.count - 1 {   // don't add the full word, only prefixes
                    prefixes.insert(running)
                }
            }
        }
        return prefixes
    }

    // MARK: - Public entry point

    func process(_ text: String) -> String {
        var result = text

        // 1. Full-width → half-width (if enabled)
        if settings.shouldNormalizeToHalfWidth {
            result = normalizeFullWidthPunctuation(result)
        }

        // 2. Quote / special character normalization
        result = normalizeSpecialCharacters(result)

        // 3. Cross-line hyphen merging
        result = mergeHyphenatedWords(result)

        // 4. Noise line removal
        result = removeNoiseLines(result)

        // 5. Clean whitespace
        result = cleanWhitespace(result)

        return result
    }

    // MARK: - 1. Full-width → half-width punctuation

    /// Map every full-width punctuation character to its ASCII half-width equivalent.
    private static let fullWidthMap: [Character: Character] = [
        "\u{FF08}": "(",   // （
        "\u{FF09}": ")",   // ）
        "\u{FF3B}": "[",   // ［
        "\u{FF3D}": "]",   // ］
        "\u{FF1A}": ":",   // ：
        "\u{FF1B}": ";",   // ；
        "\u{FF0C}": ",",   // ，
        "\u{FF0E}": ".",   // ．
        "\u{FF1C}": "<",   // ＜
        "\u{FF1E}": ">",   // ＞
        "\u{FF0B}": "+",   // ＋
        "\u{FF0D}": "-",   // －
        "\u{FF1D}": "=",   // ＝
        "\u{FF5B}": "{",   // ｛
        "\u{FF5D}": "}",   // ｝
        "\u{FF0F}": "/",   // ／
        "\u{FF3C}": "\\",  // ＼
        "\u{FF01}": "!",   // ！
        "\u{FF1F}": "?",   // ？
    ]

    func normalizeFullWidthPunctuation(_ text: String) -> String {
        var chars = Array(text)
        for i in chars.indices {
            if let replacement = Self.fullWidthMap[chars[i]] {
                chars[i] = replacement
            }
        }
        return String(chars)
    }

    // MARK: - 2. Special character normalization

    func normalizeSpecialCharacters(_ text: String) -> String {
        var result = text

        // Curly single quotes / apostrophes → straight apostrophe
        result = result.replacingOccurrences(of: "\u{2018}", with: "'")  // '
        result = result.replacingOccurrences(of: "\u{2019}", with: "'")  // '

        // Curly double quotes → straight double quote
        result = result.replacingOccurrences(of: "\u{201C}", with: "\"") // "
        result = result.replacingOccurrences(of: "\u{201D}", with: "\"") // "

        // En-dash and em-dash → hyphen-minus
        result = result.replacingOccurrences(of: "\u{2013}", with: "-")  // –
        result = result.replacingOccurrences(of: "\u{2014}", with: "-")  // —

        // Guillemets → double quote
        result = result.replacingOccurrences(of: "\u{00AB}", with: "\"") // «
        result = result.replacingOccurrences(of: "\u{00BB}", with: "\"") // »

        // Horizontal ellipsis → three dots
        result = result.replacingOccurrences(of: "\u{2026}", with: "...") // …

        // NOTE: We intentionally do NOT replace → (U+2192, rightwards arrow).
        // It carries semantic meaning in diagrams and protocol descriptions.

        return result
    }

    // MARK: - 3. Cross-line hyphen merging

    func mergeHyphenatedWords(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let prefixes = preservePrefixes

        var i = 0
        while i < lines.count - 1 {
            let currentLine = lines[i]
            let nextLine = lines[i + 1]

            // Check if current line ends with  word-  pattern
            guard currentLine.hasSuffix("-"),
                  let lastHyphenIdx = currentLine.lastIndex(of: "-"),
                  lastHyphenIdx == currentLine.index(before: currentLine.endIndex)
            else {
                i += 1
                continue
            }

            let trimmedNext = nextLine.trimmingCharacters(in: .whitespaces)
            guard !trimmedNext.isEmpty else {
                i += 1
                continue
            }

            let firstCharOfNext = trimmedNext[trimmedNext.startIndex]

            // Extract the prefix word (text before the trailing hyphen)
            let beforeHyphen = String(currentLine[currentLine.startIndex..<lastHyphenIdx])
            let prefixWord = extractLastWord(from: beforeHyphen)

            // Extract continuation word (first word of next line)
            let continuationWord = extractFirstWord(from: trimmedNext)

            // --- ALL-CAPS case: RELAT-\nED → RELATED ---
            if !prefixWord.isEmpty,
               prefixWord == prefixWord.uppercased(),
               !continuationWord.isEmpty,
               continuationWord == continuationWord.uppercased(),
               continuationWord.first?.isLetter == true
            {
                // Check preserve list
                let candidate = prefixWord + "-" + continuationWord
                if !isPreserved(candidate: candidate, prefixes: prefixes) {
                    lines[i] = String(currentLine.dropLast()) + continuationWord
                    // Remove the continuation word from next line
                    lines[i + 1] = String(trimmedNext.dropFirst(continuationWord.count))
                        .trimmingCharacters(in: .whitespaces)
                    if lines[i + 1].isEmpty {
                        lines.remove(at: i + 1)
                    }
                    // Don't advance i — re-check merged line
                    continue
                }
            }

            // --- Lowercase continuation case: configur-\nation → configuration ---
            if firstCharOfNext.isLowercase {
                let candidate = prefixWord + "-" + continuationWord
                if !isPreserved(candidate: candidate, prefixes: prefixes) {
                    lines[i] = String(currentLine.dropLast()) + continuationWord
                    lines[i + 1] = String(trimmedNext.dropFirst(continuationWord.count))
                        .trimmingCharacters(in: .whitespaces)
                    if lines[i + 1].isEmpty {
                        lines.remove(at: i + 1)
                    }
                    continue
                }
            }

            // --- Mixed case: keep hyphen but join lines ---
            // Cases like Rel-\n17, G-\nRNTIs, moto-\nbikes
            // These have a legitimate hyphen (not a line-break artifact), so we
            // JOIN the lines but KEEP the hyphen: Rel-\n17 → Rel-17
            if !prefixWord.isEmpty && (firstCharOfNext.isLetter || firstCharOfNext.isNumber) {
                // Only join if the continuation word is on the next line (not a compound preserved above)
                let candidate = prefixWord + "-" + continuationWord
                if !isPreserved(candidate: candidate, prefixes: prefixes) {
                    // Keep the hyphen, just remove the line break
                    lines[i] = currentLine + continuationWord  // currentLine already ends with "-"
                    lines[i + 1] = String(trimmedNext.dropFirst(continuationWord.count))
                        .trimmingCharacters(in: .whitespaces)
                    if lines[i + 1].isEmpty {
                        lines.remove(at: i + 1)
                    }
                    continue
                }
            }

            i += 1
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - 4. Noise line removal

    /// Remove lines that consist of a single non-alphanumeric character — these are
    /// typically watermark artifacts or OCR noise.
    func removeNoiseLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.count == 1,
               let scalar = trimmed.unicodeScalars.first,
               !CharacterSet.alphanumerics.contains(scalar) {
                return false  // drop this noise line
            }
            return true
        }
        return filtered.joined(separator: "\n")
    }

    // MARK: - 5. Whitespace cleanup

    /// Collapse runs of 3+ blank lines into 2, and trim trailing whitespace on each line.
    func cleanWhitespace(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")

        // Trim trailing whitespace per line
        var trimmed = lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }

        // Collapse 3+ consecutive blank lines → 2
        var result: [String] = []
        var blankCount = 0
        for line in trimmed {
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

    // MARK: - Helpers

    /// Extract the last word (contiguous letters/digits) from a string.
    private func extractLastWord(from str: String) -> String {
        var word = ""
        for ch in str.reversed() {
            if ch.isLetter || ch.isNumber {
                word.append(ch)
            } else {
                break
            }
        }
        return String(word.reversed())
    }

    /// Extract the first word (contiguous letters/digits) from a string.
    private func extractFirstWord(from str: String) -> String {
        var word = ""
        for ch in str {
            if ch.isLetter || ch.isNumber {
                word.append(ch)
            } else {
                break
            }
        }
        return word
    }

    /// Check whether a candidate hyphenated form (e.g. "UE-specific") matches
    /// any entry in the preserve list, case-insensitively.
    private func isPreserved(candidate: String, prefixes: Set<String>) -> Bool {
        let lower = candidate.lowercased()
        // Direct match against the full preserve list
        if preserveList.contains(where: { $0.lowercased() == lower }) {
            return true
        }
        // Check if the prefix part (before the last hyphen) appears as a known
        // compound-word prefix — meaning the hyphen is structural, not a line-break artifact.
        if let lastHyphen = lower.lastIndex(of: "-") {
            let prefix = String(lower[lower.startIndex..<lastHyphen])
            if prefixes.contains(prefix) {
                return true
            }
        }
        return false
    }

    // MARK: - External preserve list loading

    /// Attempt to load an external preserve list from a known location.
    /// File format: one hyphenated word per line; blank lines and #-comments are ignored.
    /// Returns nil if no file is found.
    private static func loadExternalPreserveList() -> Set<String>? {
        // Look in Application Support / Doc2Md / hyphen-preserve.txt
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let fileURL = appSupport
            .appendingPathComponent("Doc2Md", isDirectory: true)
            .appendingPathComponent("hyphen-preserve.txt")

        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        var words = Set<String>()
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            words.insert(trimmed)
        }
        return words.isEmpty ? nil : words
    }
}
