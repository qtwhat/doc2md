import Foundation

// MARK: - File Type Detector
//
// Resolves "what kind of file is this?" by reading the file's magic bytes
// instead of trusting the extension alone. This makes the app tolerant to
// renamed files (e.g., `report` with no extension, or a PDF saved as
// `notes.txt`).
//
// Strategy:
//   1. Read the first 16 bytes.
//   2. Look up a canonical extension from the magic signature table.
//   3. If the original extension is in the same "family" as the magic
//      (ZIP-family for docx/pptx/xlsx/epub; OLE-family for doc/xls/ppt/msg),
//      keep the original — these signatures don't uniquely identify the
//      sub-format and the extension is the better hint.
//   4. Otherwise prefer the magic-derived extension.
//
// Returns the original extension on any error so the caller's existing
// switch keeps working.

enum FileTypeDetector {

    static func resolve(url: URL) -> String {
        let original = url.pathExtension.lowercased()
        guard let head = readHead(url: url, n: 16),
              let magic = matchMagic(head) else {
            return original
        }
        if isInFamily(extension: original, magic: magic) {
            return original
        }
        return magic
    }

    // MARK: - Magic Signatures

    private static func matchMagic(_ head: Data) -> String? {
        let bytes = [UInt8](head)

        // PDF: %PDF
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }

        // ZIP-family: PK\x03\x04 — could be zip, docx, pptx, xlsx, epub
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "zip" }

        // OLE Compound Document: D0 CF 11 E0 A1 B1 1A E1 — doc/xls/ppt/msg
        if bytes.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) { return "msg" }

        // PNG
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }

        // JPEG / JFIF / EXIF
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }

        // GIF8(7|9)a
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }

        // BMP
        if bytes.starts(with: [0x42, 0x4D]) { return "bmp" }

        // TIFF (little / big endian)
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) { return "tiff" }
        if bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }

        // HEIC / HEIF — ISO BMFF "ftyp" box, brand at offset 8
        if bytes.count >= 12, bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
            if ["heic", "heix", "mif1", "msf1", "heim", "heis"].contains(brand) { return "heic" }
        }

        // WebP — RIFF....WEBP
        if bytes.count >= 12,
           bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return "webp"
        }

        // RTF: {\rtf
        if bytes.starts(with: [0x7B, 0x5C, 0x72, 0x74, 0x66]) { return "rtf" }

        // EML: heuristic — starts with a header-like line ("From:", "Return-Path:",
        // "Received:", etc.). We only consult this as a tiebreaker when the
        // original extension is empty / unknown, to avoid false positives on
        // plain text files that happen to start with "From".
        return nil
    }

    /// True if the magic-derived extension and the user-supplied extension
    /// belong to the same container family. ZIP magic could mean .docx, so
    /// we should not "correct" .docx to .zip.
    private static func isInFamily(extension ext: String, magic: String) -> Bool {
        switch magic {
        case "zip":
            return ["zip", "docx", "pptx", "xlsx", "epub"].contains(ext)
        case "msg":
            return ["msg", "doc", "xls", "ppt"].contains(ext)
        case "tiff":
            return ["tif", "tiff"].contains(ext)
        case "jpg":
            return ["jpg", "jpeg"].contains(ext)
        case "heic":
            return ["heic", "heif"].contains(ext)
        default:
            return ext == magic
        }
    }

    // MARK: - I/O

    private static func readHead(url: URL, n: Int) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        return try? fh.read(upToCount: n)
    }
}
