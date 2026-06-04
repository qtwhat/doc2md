import Foundation

enum XmlConverterError: LocalizedError {
    case readFailed(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .readFailed(let msg): return "XML 读取失败: \(msg)"
        case .empty:               return "XML 文件为空"
        }
    }
}

// MARK: - Converter
//
// Pretty-prints XML inside a fenced code block. Uses Foundation's
// XMLDocument when available to normalize formatting; falls back to raw
// passthrough when the input is malformed (we still want to give the user
// SOMETHING rather than refusing to convert).

struct XmlConverter {
    func convert(url: URL) throws -> String {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw XmlConverterError.readFailed(error.localizedDescription) }
        guard !data.isEmpty else { throw XmlConverterError.empty }

        let title = url.deletingPathExtension().lastPathComponent

        if let doc = try? XMLDocument(data: data, options: []) {
            let pretty = doc.xmlString(options: [.nodePrettyPrint, .nodeCompactEmptyElement])
            return "# \(title)\n\n```xml\n\(pretty)\n```\n"
        }

        let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return "# \(title)\n\n```xml\n\(raw)\n```\n"
    }
}
