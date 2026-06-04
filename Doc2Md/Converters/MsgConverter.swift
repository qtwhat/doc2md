import Foundation

// MARK: - Errors

enum MsgConverterError: LocalizedError {
    case readFailed(String)
    case notOleFile
    case malformed(String)
    case noBody

    var errorDescription: String? {
        switch self {
        case .readFailed(let msg):  return ".msg 读取失败: \(msg)"
        case .notOleFile:           return "文件不是 OLE Compound Document（.msg / .doc / .xls / .ppt 共用此容器格式）"
        case .malformed(let msg):   return ".msg 文件结构损坏: \(msg)"
        case .noBody:               return ".msg 未找到邮件正文"
        }
    }
}

// MARK: - MSG Converter
//
// Outlook .msg files are OLE Compound File Binary (CFB / "OLE2") containers.
// Inside the container, MAPI properties live in streams named:
//
//     __substg1.0_<PROPID 4 hex><TYPE 4 hex>
//
// Type codes we care about:
//   001F = PT_UNICODE      (UTF-16-LE string)
//   001E = PT_STRING8      (ANSI string, codepage-dependent)
//   0102 = PT_BINARY
//
// Property IDs we extract:
//   0037 PR_SUBJECT
//   003D PR_SUBJECT_PREFIX
//   0042 PR_SENT_REPRESENTING_NAME
//   0C1A PR_SENDER_NAME
//   0C1F PR_SENDER_EMAIL_ADDRESS
//   0E04 PR_DISPLAY_TO
//   0E03 PR_DISPLAY_CC
//   1000 PR_BODY                       (plain text body)
//   1013 PR_BODY_HTML                  (HTML body)
//   007D PR_TRANSPORT_MESSAGE_HEADERS  (raw RFC 5322 headers)
//
// We prefer the HTML body via XHtmlToMarkdown; fall back to plain body.
//
// This file embeds a minimal OLE CFB reader. It handles:
//   - 512-byte sector v3 files (the common .msg shape)
//   - DIFAT entries in the header (109 entries; extension sectors not needed
//     for typical .msg files under ~7 MB)
//   - Linear traversal of the directory entries (we don't walk the red-black
//     tree; we just enumerate every entry which is correct for a flat lookup)
//   - Regular FAT and mini-FAT stream reads

struct MsgConverter {
    func convert(url: URL) throws -> String {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw MsgConverterError.readFailed(error.localizedDescription) }

        let ole = try OLEFile(data: data)
        let streams = ole.allStreams()

        // Extract well-known MAPI properties
        func str(_ pid: String) -> String? {
            // PT_UNICODE first, then PT_STRING8 fallback
            if let u = streams["__substg1.0_\(pid)001F"] {
                return decodeUTF16LE(u)
            }
            if let a = streams["__substg1.0_\(pid)001E"] {
                return String(data: a, encoding: .utf8)
                    ?? String(data: a, encoding: .isoLatin1)
            }
            return nil
        }

        let subject  = str("0037") ?? str("003D") ?? ""
        let from     = [str("0C1A"), str("0C1F")].compactMap { $0 }.filter { !$0.isEmpty }
                        .joined(separator: " <") + (str("0C1F") != nil ? ">" : "")
        let to       = str("0E04") ?? ""
        let cc       = str("0E03") ?? ""
        let bodyHTML = str("1013")
        let bodyPlain = str("1000")
        let headers  = str("007D")

        // Build body Markdown
        var bodyMarkdown = ""
        if let html = bodyHTML, !html.isEmpty,
           let htmlData = html.data(using: .utf8),
           let md = try? XHtmlToMarkdown.convert(data: htmlData),
           !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bodyMarkdown = md
        } else if let plain = bodyPlain, !plain.isEmpty {
            bodyMarkdown = plain
        }

        guard !bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !subject.isEmpty else {
            throw MsgConverterError.noBody
        }

        // Header summary block
        var out = ""
        if !subject.isEmpty {
            out += "# \(subject)\n\n"
        }
        if !from.isEmpty   { out += "- **From:** \(from)\n" }
        if !to.isEmpty     { out += "- **To:** \(to)\n" }
        if !cc.isEmpty     { out += "- **Cc:** \(cc)\n" }
        if let h = headers, !h.isEmpty {
            // Pull a Date: line out of the raw headers if present.
            for line in h.components(separatedBy: .newlines) {
                if line.lowercased().hasPrefix("date:") {
                    let v = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    out += "- **Date:** \(v)\n"
                    break
                }
            }
        }
        if !out.isEmpty { out += "\n---\n\n" }
        out += bodyMarkdown
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    // MARK: - UTF-16-LE decoder (handles missing BOM, stops at first NUL pair)

    private func decodeUTF16LE(_ data: Data) -> String? {
        // MAPI PT_UNICODE streams are UTF-16-LE without BOM. Strip a trailing
        // NUL terminator if present.
        var bytes = data
        if bytes.count >= 2, bytes[bytes.count - 2] == 0, bytes[bytes.count - 1] == 0 {
            bytes.removeLast(2)
        }
        return String(data: bytes, encoding: .utf16LittleEndian)
    }
}

// MARK: - OLE Compound File Binary Reader
//
// Minimal v3 reader (512-byte sectors). Spec: MS-CFB.
// https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-cfb/

private struct OLEFile {
    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniStreamCutoff: UInt32
    private let fat: [UInt32]
    private let miniFat: [UInt32]
    private let directory: [DirEntry]
    private let miniStream: Data

    private static let END_OF_CHAIN: UInt32 = 0xFFFFFFFE
    private static let FREE_SECTOR: UInt32  = 0xFFFFFFFF

    init(data: Data) throws {
        self.data = data

        // Header check
        guard data.count >= 512 else { throw MsgConverterError.notOleFile }
        let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        guard data.prefix(8).elementsEqual(magic) else { throw MsgConverterError.notOleFile }

        // Sector sizes from header
        let sectorShift = OLEFile.u16(data, at: 30)
        let miniSectorShift = OLEFile.u16(data, at: 32)
        self.sectorSize = 1 << Int(sectorShift)
        self.miniSectorSize = 1 << Int(miniSectorShift)
        self.miniStreamCutoff = OLEFile.u32(data, at: 56)

        guard self.sectorSize == 512 || self.sectorSize == 4096 else {
            throw MsgConverterError.malformed("unsupported sector size \(self.sectorSize)")
        }

        // FAT — first 109 entries in header (DIFAT). Extension sectors are
        // rare in .msg files; we ignore them and just process the first 109,
        // which covers ~54 KB of FAT (=27 MB of stream space) at 512-byte
        // sectors. Plenty for normal .msg files.
        let numFatSectors = OLEFile.u32(data, at: 44)
        var fatSectors: [UInt32] = []
        for i in 0..<min(Int(numFatSectors), 109) {
            let s = OLEFile.u32(data, at: 76 + i * 4)
            if s < OLEFile.FREE_SECTOR { fatSectors.append(s) }
        }
        var fat: [UInt32] = []
        for fs in fatSectors {
            let sec = try OLEFile.readSector(data, sectorIndex: fs, sectorSize: sectorSize)
            for i in stride(from: 0, to: sec.count, by: 4) {
                fat.append(OLEFile.u32(sec, at: i))
            }
        }
        self.fat = fat

        // Directory chain
        let dirStart = OLEFile.u32(data, at: 48)
        let dirChain = try OLEFile.chain(fat: fat, start: dirStart)
        var dirData = Data()
        for s in dirChain {
            dirData.append(try OLEFile.readSector(data, sectorIndex: s, sectorSize: sectorSize))
        }
        var dir: [DirEntry] = []
        for i in stride(from: 0, to: dirData.count, by: 128) {
            if let e = DirEntry(slice: dirData.subdata(in: i..<min(i+128, dirData.count))) {
                dir.append(e)
            }
        }
        guard !dir.isEmpty else { throw MsgConverterError.malformed("empty directory") }
        self.directory = dir

        // Mini-FAT
        let miniFatStart = OLEFile.u32(data, at: 60)
        var miniFat: [UInt32] = []
        if miniFatStart != OLEFile.END_OF_CHAIN && miniFatStart != OLEFile.FREE_SECTOR {
            let miniFatChain = try OLEFile.chain(fat: fat, start: miniFatStart)
            for s in miniFatChain {
                let sec = try OLEFile.readSector(data, sectorIndex: s, sectorSize: sectorSize)
                for i in stride(from: 0, to: sec.count, by: 4) {
                    miniFat.append(OLEFile.u32(sec, at: i))
                }
            }
        }
        self.miniFat = miniFat

        // Mini-stream lives inside the Root Entry's regular FAT-allocated stream.
        let root = dir[0]
        let miniStreamChain = (try? OLEFile.chain(fat: fat, start: root.startSector)) ?? []
        var miniStream = Data()
        for s in miniStreamChain {
            miniStream.append((try? OLEFile.readSector(data, sectorIndex: s, sectorSize: sectorSize)) ?? Data())
        }
        if miniStream.count > Int(root.size) {
            miniStream = miniStream.prefix(Int(root.size))
        }
        self.miniStream = miniStream
    }

    // MARK: - Public

    /// Enumerate every named stream in the file. We linearly scan all
    /// directory entries (type==2) — no red-black-tree walk needed.
    func allStreams() -> [String: Data] {
        var out: [String: Data] = [:]
        for (idx, entry) in directory.enumerated() {
            guard entry.type == 2, !entry.name.isEmpty else { continue }
            if let bytes = readStream(at: idx) {
                out[entry.name] = bytes
            }
        }
        return out
    }

    // MARK: - Stream Reading

    private func readStream(at dirIndex: Int) -> Data? {
        guard dirIndex < directory.count else { return nil }
        let entry = directory[dirIndex]
        let size = Int(entry.size)
        if size == 0 { return Data() }

        // Streams smaller than miniStreamCutoff live in the mini-stream,
        // chained via the mini-FAT.
        if entry.size < miniStreamCutoff {
            return readMiniStream(start: entry.startSector, size: size)
        }
        // Regular stream
        guard let chain = try? OLEFile.chain(fat: fat, start: entry.startSector) else { return nil }
        var bytes = Data()
        for s in chain {
            guard let sec = try? OLEFile.readSector(data, sectorIndex: s, sectorSize: sectorSize) else { return nil }
            bytes.append(sec)
        }
        return bytes.prefix(size)
    }

    private func readMiniStream(start: UInt32, size: Int) -> Data? {
        var bytes = Data()
        var s = start
        while s != OLEFile.END_OF_CHAIN && s < OLEFile.FREE_SECTOR {
            let offset = Int(s) * miniSectorSize
            guard offset + miniSectorSize <= miniStream.count else { break }
            bytes.append(miniStream.subdata(in: offset..<(offset + miniSectorSize)))
            guard Int(s) < miniFat.count else { break }
            s = miniFat[Int(s)]
        }
        return bytes.prefix(size)
    }

    // MARK: - Helpers

    private static func chain(fat: [UInt32], start: UInt32) throws -> [UInt32] {
        var out: [UInt32] = []
        var s = start
        var hops = 0
        while s != END_OF_CHAIN && s < FREE_SECTOR {
            out.append(s)
            guard Int(s) < fat.count else { break }
            s = fat[Int(s)]
            hops += 1
            if hops > 1_000_000 {
                throw MsgConverterError.malformed("FAT chain too long; loop?")
            }
        }
        return out
    }

    private static func readSector(_ data: Data, sectorIndex: UInt32, sectorSize: Int) throws -> Data {
        // Sector 0 starts immediately AFTER the 512-byte header.
        let offset = 512 + Int(sectorIndex) * sectorSize
        guard offset >= 0, offset + sectorSize <= data.count else {
            throw MsgConverterError.malformed("sector \(sectorIndex) out of range")
        }
        return data.subdata(in: offset..<(offset + sectorSize))
    }

    private static func u16(_ d: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= d.count else { return 0 }
        return UInt16(d[offset]) | (UInt16(d[offset + 1]) << 8)
    }

    private static func u32(_ d: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= d.count else { return 0 }
        return UInt32(d[offset])
             | (UInt32(d[offset + 1]) << 8)
             | (UInt32(d[offset + 2]) << 16)
             | (UInt32(d[offset + 3]) << 24)
    }
}

// MARK: - Directory Entry

private struct DirEntry {
    let name: String
    let type: UInt8         // 0=empty 1=storage 2=stream 5=root
    let startSector: UInt32
    let size: UInt32        // for streams: byte size

    init?(slice: Data) {
        guard slice.count >= 128 else { return nil }
        // Name is UTF-16-LE, length-prefixed by byte count at offset 64
        let nameByteLen = UInt16(slice[64]) | (UInt16(slice[65]) << 8)
        guard nameByteLen <= 64, nameByteLen >= 2 else {
            // Allow zero-length root if type allows; else reject
            self.name = ""
            self.type = slice[66]
            self.startSector = DirEntry.u32(slice, at: 116)
            self.size = DirEntry.u32(slice, at: 120)
            if self.type == 0 { return nil }
            return
        }
        // Name length includes the trailing NUL terminator (2 bytes).
        let nameBytes = slice.subdata(in: 0..<Int(nameByteLen - 2))
        self.name = String(data: nameBytes, encoding: .utf16LittleEndian) ?? ""
        self.type = slice[66]
        self.startSector = DirEntry.u32(slice, at: 116)
        self.size = DirEntry.u32(slice, at: 120)
    }

    private static func u32(_ d: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= d.count else { return 0 }
        return UInt32(d[offset])
             | (UInt32(d[offset + 1]) << 8)
             | (UInt32(d[offset + 2]) << 16)
             | (UInt32(d[offset + 3]) << 24)
    }
}
