import Foundation

// MARK: - Errors

enum EmlConverterError: LocalizedError {
    case readFailed(String)
    case noBody

    var errorDescription: String? {
        switch self {
        case .readFailed(let msg): return "EML 读取失败: \(msg)"
        case .noBody: return "EML 中未找到正文"
        }
    }
}

// MARK: - Converter
//
// Parses RFC 5322 (formerly RFC 822/2822) email messages into Markdown.
//
// Strategy:
//   1. Split headers from body at the first empty line.
//   2. Parse headers, unfolding continuation lines and decoding
//      RFC 2047 encoded-words ("=?UTF-8?B?...?=" / "=?UTF-8?Q?...?=").
//   3. If Content-Type is multipart/*, walk the parts by boundary and
//      pick the best body (prefer text/html; fall back to text/plain).
//   4. Decode Content-Transfer-Encoding (base64 / quoted-printable / 7bit).
//   5. text/html → reuse XHtmlToMarkdown. text/plain → emit verbatim
//      (after newline normalisation).
//   6. Prepend a small header block: From / To / Cc / Subject / Date.

struct EmlConverter {
    func convert(url: URL) throws -> String {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw EmlConverterError.readFailed(error.localizedDescription) }

        let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)

        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let (headerBlock, bodyText) = splitHeaderBody(normalized)
        let headers = parseHeaders(headerBlock)

        let bodyMarkdown = try renderBody(headers: headers, bodyText: bodyText)
        guard !bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EmlConverterError.noBody
        }

        var output = renderHeaderSummary(headers)
        output += "\n\n---\n\n"
        output += bodyMarkdown
        if !output.hasSuffix("\n") { output += "\n" }
        return output
    }

    // MARK: - Split

    private func splitHeaderBody(_ raw: String) -> (String, String) {
        if let range = raw.range(of: "\n\n") {
            return (String(raw[..<range.lowerBound]),
                    String(raw[range.upperBound...]))
        }
        return (raw, "")
    }

    // MARK: - Header Parsing

    private func parseHeaders(_ block: String) -> [(String, String)] {
        var headers: [(String, String)] = []
        var current: (name: String, value: String)? = nil

        for line in block.components(separatedBy: "\n") {
            // Folded continuation: starts with whitespace, append to previous value.
            if let first = line.first, first == " " || first == "\t", current != nil {
                current!.value += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            if let colon = line.firstIndex(of: ":") {
                if let c = current {
                    headers.append((c.name, decodeEncodedWords(c.value.trimmingCharacters(in: .whitespaces))))
                }
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                current = (name, value)
            }
        }
        if let c = current {
            headers.append((c.name, decodeEncodedWords(c.value.trimmingCharacters(in: .whitespaces))))
        }
        return headers
    }

    private func headerValue(_ headers: [(String, String)], _ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first(where: { $0.0.lowercased() == lower })?.1
    }

    // MARK: - RFC 2047 Encoded-Word Decoding
    //
    // Format: =?charset?B?base64?=  or  =?charset?Q?quoted-printable?=
    // Multiple encoded-words separated only by whitespace are joined.

    private func decodeEncodedWords(_ s: String) -> String {
        let pattern = "=\\?([^?]+)\\?([BbQq])\\?([^?]+)\\?="
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }

        var result = ""
        var lastEnd = s.startIndex
        var lastWasEncoded = false

        let nsRange = NSRange(s.startIndex..<s.endIndex, in: s)
        let matches = regex.matches(in: s, range: nsRange)

        for m in matches {
            guard let range = Range(m.range, in: s),
                  let charsetR = Range(m.range(at: 1), in: s),
                  let encR = Range(m.range(at: 2), in: s),
                  let textR = Range(m.range(at: 3), in: s) else { continue }

            let between = String(s[lastEnd..<range.lowerBound])
            // Per RFC 2047: drop whitespace between consecutive encoded-words.
            if lastWasEncoded && between.trimmingCharacters(in: .whitespaces).isEmpty {
                // skip
            } else {
                result += between
            }

            let charset = String(s[charsetR])
            let enc = String(s[encR]).uppercased()
            let payload = String(s[textR])

            let bytes: Data?
            if enc == "B" {
                bytes = Data(base64Encoded: payload)
            } else {
                bytes = quotedPrintableDecode(payload.replacingOccurrences(of: "_", with: " "))
            }

            if let bytes = bytes,
               let decoded = String(data: bytes, encoding: encodingFor(charset: charset)) {
                result += decoded
            } else {
                result += String(s[range])
            }

            lastEnd = range.upperBound
            lastWasEncoded = true
        }
        result += String(s[lastEnd..<s.endIndex])
        return result
    }

    private func encodingFor(charset: String) -> String.Encoding {
        let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        if cf == kCFStringEncodingInvalidId { return .utf8 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    // MARK: - Quoted-Printable

    private func quotedPrintableDecode(_ s: String) -> Data? {
        var out = Data()
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "=" && i + 2 < chars.count {
                let hex = String(chars[i + 1]) + String(chars[i + 2])
                if hex == "\r\n" || hex == "\n " {
                    i += 3; continue
                }
                if let byte = UInt8(hex, radix: 16) {
                    out.append(byte)
                    i += 3
                    continue
                }
                if chars[i + 1] == "\n" {
                    i += 2; continue
                }
            }
            if let b = String(c).data(using: .utf8) {
                out.append(b)
            }
            i += 1
        }
        return out
    }

    // MARK: - Body Rendering

    private struct BodyPart {
        let mimeType: String        // e.g. "text/html", "text/plain"
        let charset: String?
        let encoding: String        // "base64" / "quoted-printable" / "7bit" / ...
        let raw: String             // raw (still encoded) part body
    }

    private func renderBody(headers: [(String, String)], bodyText: String) throws -> String {
        let contentType = headerValue(headers, "Content-Type") ?? "text/plain"
        let cte = headerValue(headers, "Content-Transfer-Encoding") ?? "7bit"
        let mime = contentType.components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? "text/plain"

        if mime.hasPrefix("multipart/") {
            guard let boundary = parseParam(contentType, key: "boundary") else {
                return decodeAndRender(part: BodyPart(
                    mimeType: "text/plain", charset: parseParam(contentType, key: "charset"),
                    encoding: cte, raw: bodyText))
            }
            let parts = splitMultipart(bodyText, boundary: boundary)
            // Prefer the first text/html part. Fall back to text/plain.
            // Recurse for nested multipart/* (e.g. multipart/related inside).
            if let html = pickPart(parts: parts, prefer: "text/html") {
                return decodeAndRender(part: html)
            }
            if let plain = pickPart(parts: parts, prefer: "text/plain") {
                return decodeAndRender(part: plain)
            }
            // Nested multipart fallback
            for p in parts where p.mimeType.hasPrefix("multipart/") {
                let nestedHeaders: [(String, String)] = [
                    ("Content-Type", "\(p.mimeType); boundary=\(parseParam(p.mimeType, key: "boundary") ?? "")"),
                    ("Content-Transfer-Encoding", p.encoding)
                ]
                if let nested = try? renderBody(headers: nestedHeaders, bodyText: p.raw),
                   !nested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return nested
                }
            }
            return ""
        }

        return decodeAndRender(part: BodyPart(
            mimeType: mime,
            charset: parseParam(contentType, key: "charset"),
            encoding: cte,
            raw: bodyText))
    }

    private func decodeAndRender(part: BodyPart) -> String {
        let decoded = decodePartPayload(part)
        if part.mimeType == "text/html" {
            if let data = decoded.data(using: .utf8),
               let md = try? XHtmlToMarkdown.convert(data: data) {
                return md
            }
            return decoded
        }
        // text/plain (or unknown) — paragraph-aware: blank line preserved as
        // \n\n, single \n collapsed to space inside a paragraph.
        return normalizePlainText(decoded)
    }

    private func decodePartPayload(_ part: BodyPart) -> String {
        let enc = part.encoding.lowercased()
        let charset = part.charset ?? "utf-8"
        let stringEnc = encodingFor(charset: charset)

        switch enc {
        case "base64":
            let cleaned = part.raw.components(separatedBy: .whitespacesAndNewlines).joined()
            if let data = Data(base64Encoded: cleaned),
               let s = String(data: data, encoding: stringEnc) {
                return s
            }
            return part.raw
        case "quoted-printable":
            if let data = quotedPrintableDecode(part.raw),
               let s = String(data: data, encoding: stringEnc) {
                return s
            }
            return part.raw
        default:
            // 7bit / 8bit / binary / unknown — re-decode under declared charset
            // if we have raw bytes; else pass through.
            if charset.lowercased() != "utf-8",
               let data = part.raw.data(using: .isoLatin1),
               let s = String(data: data, encoding: stringEnc) {
                return s
            }
            return part.raw
        }
    }

    private func normalizePlainText(_ s: String) -> String {
        // Preserve blank lines as paragraph separators. Collapse single
        // newlines (which in plain-text email are usually line wrapping)
        // into spaces within a paragraph, unless the next line is clearly
        // a quoted reply (starts with ">").
        let paragraphs = s.components(separatedBy: "\n\n")
        let merged = paragraphs.map { para -> String in
            let lines = para.components(separatedBy: "\n")
            var out: [String] = []
            for line in lines {
                if line.hasPrefix(">") || out.last?.hasPrefix(">") == true {
                    out.append(line)
                } else if out.isEmpty {
                    out.append(line)
                } else {
                    out[out.count - 1] += " " + line
                }
            }
            return out.joined(separator: "\n")
        }
        return merged.joined(separator: "\n\n")
    }

    // MARK: - Multipart Splitting

    private func splitMultipart(_ body: String, boundary: String) -> [BodyPart] {
        let delim = "--\(boundary)"
        let close = "--\(boundary)--"

        var parts: [BodyPart] = []
        let segments = body.components(separatedBy: delim)
        for raw in segments {
            var segment = raw
            if segment.hasPrefix("--") { continue }   // closing delimiter prefix
            if segment.hasPrefix("\n") { segment.removeFirst() }
            if segment.contains(close) { continue }
            if segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

            let (hdrBlock, partBody) = splitHeaderBody(segment)
            let hdrs = parseHeaders(hdrBlock)
            let ct = headerValue(hdrs, "Content-Type") ?? "text/plain"
            let cte = headerValue(hdrs, "Content-Transfer-Encoding") ?? "7bit"
            let mime = ct.components(separatedBy: ";").first?
                .trimmingCharacters(in: .whitespaces).lowercased() ?? "text/plain"
            parts.append(BodyPart(
                mimeType: mime,
                charset: parseParam(ct, key: "charset"),
                encoding: cte,
                raw: partBody.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return parts
    }

    private func pickPart(parts: [BodyPart], prefer: String) -> BodyPart? {
        parts.first(where: { $0.mimeType == prefer })
    }

    private func parseParam(_ headerValue: String, key: String) -> String? {
        let parts = headerValue.components(separatedBy: ";")
        let needle = key.lowercased()
        for p in parts.dropFirst() {
            let kv = p.components(separatedBy: "=")
            guard kv.count == 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            if k == needle {
                var v = kv[1].trimmingCharacters(in: .whitespaces)
                if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                    v = String(v.dropFirst().dropLast())
                }
                return v
            }
        }
        return nil
    }

    // MARK: - Header Summary Block

    private func renderHeaderSummary(_ headers: [(String, String)]) -> String {
        let interesting = ["From", "To", "Cc", "Subject", "Date"]
        var lines: [String] = []
        if let subject = headerValue(headers, "Subject"), !subject.isEmpty {
            lines.append("# \(subject)")
            lines.append("")
        }
        for name in interesting where name != "Subject" {
            if let v = headerValue(headers, name), !v.isEmpty {
                lines.append("- **\(name):** \(v)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
