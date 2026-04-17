import Foundation

enum MobiConverterError: LocalizedError {
    case invalidFile(String)
    case drmProtected
    case unsupportedCompression(String)
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .invalidFile(let msg): return "MOBI 文件无效: \(msg)"
        case .drmProtected: return "此文件受 DRM 保护，无法转换"
        case .unsupportedCompression(let s): return "不支持的压缩方式: \(s)"
        case .emptyContent: return "MOBI 文件没有文本内容"
        }
    }
}

/// Kindle MOBI / AZW / AZW3 → Markdown.
///
/// Structure: PalmDB container → MOBI header (record 0) → compressed HTML in subsequent records.
///
/// Supported:
///   - PalmDoc compression (0x0002) — standard .mobi
///   - No compression (0x0001)
///
/// Rejected with a clear error:
///   - HUFF/CDIC compression (0x4448) — encrypted/uncommon
///   - DRM-protected files
///
/// AZW3 (KF8) files begin as MOBI containers but have a KF8 "boundary" record
/// pointing to a separate set of text records. When detected we try the KF8
/// section; if KF8 is HUFF/CDIC-compressed we fall back to the legacy MOBI
/// section (which most .azw3 files include for backwards compatibility).
struct MobiConverter {
    func convert(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard data.count > 78 else {
            throw MobiConverterError.invalidFile("文件太小")
        }

        // --- Parse PalmDB header ---
        let palmDB = try parsePalmDB(data: data)
        guard palmDB.recordCount > 0 else {
            throw MobiConverterError.invalidFile("无 record")
        }

        // Record 0 contains PalmDoc header + MOBI header
        let record0 = try extractRecord(data: data, palmDB: palmDB, index: 0)
        let mobi = try parseMobiHeader(record0: record0)

        if mobi.isEncrypted {
            throw MobiConverterError.drmProtected
        }

        // If KF8 boundary present, try that first
        var textRecords: [Data] = []
        if let kf8Start = mobi.kf8BoundaryRecord, kf8Start > 0, kf8Start < palmDB.recordCount {
            // KF8 section uses its own record-0 at kf8Start
            if let kf8Record0 = try? extractRecord(data: data, palmDB: palmDB, index: kf8Start),
               let kf8Header = try? parseMobiHeader(record0: kf8Record0) {
                if !kf8Header.isEncrypted &&
                   (kf8Header.compression == 1 || kf8Header.compression == 2) {
                    // Decompress KF8 records (kf8Start+1 ... kf8Start+textRecordCount)
                    for i in 1...kf8Header.textRecordCount {
                        let idx = kf8Start + i
                        if idx >= palmDB.recordCount { break }
                        if let rec = try? extractRecord(data: data, palmDB: palmDB, index: idx) {
                            let decoded = decompress(data: rec, compression: kf8Header.compression)
                            textRecords.append(decoded)
                        }
                    }
                }
            }
        }

        // Fall back to legacy MOBI section if KF8 didn't yield content
        if textRecords.isEmpty {
            guard mobi.compression == 1 || mobi.compression == 2 else {
                throw MobiConverterError.unsupportedCompression(
                    mobi.compression == 17480 ? "HUFF/CDIC（暂不支持）" : "0x\(String(mobi.compression, radix: 16))"
                )
            }
            for i in 1...mobi.textRecordCount {
                if i >= palmDB.recordCount { break }
                if let rec = try? extractRecord(data: data, palmDB: palmDB, index: i) {
                    let decoded = decompress(data: rec, compression: mobi.compression)
                    textRecords.append(decoded)
                }
            }
        }

        // Concatenate and decode
        var allBytes = Data()
        for r in textRecords { allBytes.append(r) }
        guard !allBytes.isEmpty else {
            throw MobiConverterError.emptyContent
        }

        let htmlString: String
        if mobi.textEncoding == 65001 {  // UTF-8
            htmlString = String(data: allBytes, encoding: .utf8)
                ?? String(data: allBytes, encoding: .isoLatin1) ?? ""
        } else if mobi.textEncoding == 1252 {  // Windows-1252
            htmlString = String(data: allBytes, encoding: .windowsCP1252)
                ?? String(data: allBytes, encoding: .isoLatin1) ?? ""
        } else {
            htmlString = String(data: allBytes, encoding: .utf8)
                ?? String(data: allBytes, encoding: .isoLatin1) ?? ""
        }

        guard !htmlString.isEmpty else {
            throw MobiConverterError.emptyContent
        }

        // HTML → Markdown via shared tokenizer
        return XHtmlToMarkdown.convert(html: htmlString)
    }

    // MARK: - PalmDB

    private struct PalmDB {
        let recordCount: Int
        /// Byte offsets for each record
        let recordOffsets: [Int]
    }

    private func parsePalmDB(data: Data) throws -> PalmDB {
        // Offset 76: UInt16 recordCount (big-endian)
        let recordCount = Int(readUInt16BE(data: data, at: 76))
        guard recordCount > 0 else {
            throw MobiConverterError.invalidFile("record count = 0")
        }

        // Record info list starts at offset 78: each entry 8 bytes (4 = offset, 4 = attr/uid)
        var offsets: [Int] = []
        let baseOffset = 78
        for i in 0..<recordCount {
            let entryOffset = baseOffset + i * 8
            guard entryOffset + 4 <= data.count else {
                throw MobiConverterError.invalidFile("record table 越界")
            }
            let off = Int(readUInt32BE(data: data, at: entryOffset))
            offsets.append(off)
        }
        return PalmDB(recordCount: recordCount, recordOffsets: offsets)
    }

    private func extractRecord(data: Data, palmDB: PalmDB, index: Int) throws -> Data {
        guard index < palmDB.recordCount else {
            throw MobiConverterError.invalidFile("record \(index) 越界")
        }
        let start = palmDB.recordOffsets[index]
        let end = (index + 1 < palmDB.recordCount) ? palmDB.recordOffsets[index + 1] : data.count
        guard start >= 0, end <= data.count, start <= end else {
            throw MobiConverterError.invalidFile("record \(index) 偏移无效")
        }
        return data.subdata(in: start..<end)
    }

    // MARK: - MOBI Header

    private struct MobiHeader {
        let compression: Int        // 1=none, 2=PalmDoc, 17480=HUFF/CDIC
        let textLength: Int
        let textRecordCount: Int
        let textEncoding: Int       // 1252, 65001
        let isEncrypted: Bool
        let kf8BoundaryRecord: Int? // index of KF8 section record, or nil
    }

    private func parseMobiHeader(record0: Data) throws -> MobiHeader {
        guard record0.count >= 16 else {
            throw MobiConverterError.invalidFile("record0 太短")
        }
        // PalmDoc header (first 16 bytes)
        let compression = Int(readUInt16BE(data: record0, at: 0))
        let textLength = Int(readUInt32BE(data: record0, at: 4))
        let textRecordCount = Int(readUInt16BE(data: record0, at: 8))
        let encryption = Int(readUInt16BE(data: record0, at: 12))

        // MOBI header starts at offset 16 (if present — test for "MOBI" magic)
        var textEncoding = 1252
        var kf8Boundary: Int? = nil
        var isEncrypted = encryption != 0

        if record0.count >= 20 {
            let magicStart = 16
            let magicBytes = record0.subdata(in: magicStart..<min(magicStart + 4, record0.count))
            if let magic = String(data: magicBytes, encoding: .ascii), magic == "MOBI" {
                // Offset from MOBI header start:
                //   0x00..0x04 = "MOBI"
                //   0x04..0x08 = header length
                //   0x08..0x0C = mobi type
                //   0x0C..0x10 = text encoding
                if record0.count >= 16 + 0x10 + 4 {
                    textEncoding = Int(readUInt32BE(data: record0, at: 16 + 0x0C))
                }
                // EXTH flag at offset 0x80 from MOBI start: bit 0x40 = has EXTH
                if record0.count >= 16 + 0x80 + 4 {
                    let exthFlags = Int(readUInt32BE(data: record0, at: 16 + 0x80))
                    let hasExth = (exthFlags & 0x40) != 0
                    if hasExth {
                        let headerLen = Int(readUInt32BE(data: record0, at: 16 + 0x04))
                        let exthStart = 16 + headerLen
                        if let exth = parseExth(data: record0, offset: exthStart) {
                            if exth.drmPresent { isEncrypted = true }
                            kf8Boundary = exth.kf8BoundaryRecord
                        }
                    }
                }
            }
        }

        return MobiHeader(
            compression: compression,
            textLength: textLength,
            textRecordCount: textRecordCount,
            textEncoding: textEncoding,
            isEncrypted: isEncrypted,
            kf8BoundaryRecord: kf8Boundary
        )
    }

    // MARK: - EXTH

    private struct ExthInfo {
        var drmPresent = false
        var kf8BoundaryRecord: Int? = nil
    }

    private func parseExth(data: Data, offset: Int) -> ExthInfo? {
        guard offset + 12 <= data.count else { return nil }
        let magicBytes = data.subdata(in: offset..<offset + 4)
        guard let magic = String(data: magicBytes, encoding: .ascii), magic == "EXTH" else { return nil }

        let recordCount = Int(readUInt32BE(data: data, at: offset + 8))
        var cursor = offset + 12
        var info = ExthInfo()
        for _ in 0..<recordCount {
            guard cursor + 8 <= data.count else { break }
            let type = Int(readUInt32BE(data: data, at: cursor))
            let len = Int(readUInt32BE(data: data, at: cursor + 4))
            guard len >= 8, cursor + len <= data.count else { break }
            let payloadStart = cursor + 8
            let payloadEnd = cursor + len

            switch type {
            case 116:  // start offset — not needed
                break
            case 121:  // KF8 boundary record index
                if payloadEnd - payloadStart >= 4 {
                    info.kf8BoundaryRecord = Int(readUInt32BE(data: data, at: payloadStart))
                }
            case 401, 402, 403, 404:  // DRM-related
                info.drmPresent = true
            default: break
            }
            cursor = payloadEnd
        }
        return info
    }

    // MARK: - Decompression

    private func decompress(data: Data, compression: Int) -> Data {
        switch compression {
        case 1: return data
        case 2: return palmDocDecompress(data: data)
        default: return data  // fallback
        }
    }

    /// PalmDoc (LZ77-style) decompression.
    private func palmDocDecompress(data: Data) -> Data {
        var output = Data()
        var i = 0
        let n = data.count
        while i < n {
            let byte = data[i]
            i += 1
            switch byte {
            case 0x00:
                output.append(byte)
            case 0x01...0x08:
                // Literal run of N bytes
                let count = Int(byte)
                for _ in 0..<count {
                    if i >= n { break }
                    output.append(data[i])
                    i += 1
                }
            case 0x09...0x7F:
                // Single ASCII byte
                output.append(byte)
            case 0x80...0xBF:
                // LZ77 back-reference (2 bytes)
                if i >= n { break }
                let byte2 = data[i]
                i += 1
                let pair = (UInt16(byte) << 8) | UInt16(byte2)
                let distance = Int((pair >> 3) & 0x7FF)
                let length = Int((pair & 0x7) + 3)
                guard distance > 0, distance <= output.count else { continue }
                let start = output.count - distance
                for k in 0..<length {
                    output.append(output[start + k])
                }
            case 0xC0...0xFF:
                // Space + ASCII char
                output.append(0x20)
                output.append(byte ^ 0x80)
            default:
                output.append(byte)
            }
        }
        return output
    }

    // MARK: - Low-level readers

    private func readUInt16BE(data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1])
        return (b0 << 8) | b1
    }

    private func readUInt32BE(data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
