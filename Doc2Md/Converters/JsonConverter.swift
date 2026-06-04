import Foundation

enum JsonConverterError: LocalizedError {
    case readFailed(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .readFailed(let msg): return "JSON 读取失败: \(msg)"
        case .empty:               return "JSON 文件为空"
        }
    }
}

// MARK: - Converter
//
// Pretty-prints JSON inside a fenced code block. If the input parses, we
// re-emit it with sorted keys + 2-space indent so the output is stable
// across runs (useful for diffing). If parsing fails, we still emit the
// raw bytes verbatim so the user isn't left with nothing.

struct JsonConverter {
    func convert(url: URL) throws -> String {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw JsonConverterError.readFailed(error.localizedDescription) }
        guard !data.isEmpty else { throw JsonConverterError.empty }

        let title = url.deletingPathExtension().lastPathComponent

        if let obj = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]),
           let pretty = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let s = String(data: pretty, encoding: .utf8) {
            return "# \(title)\n\n```json\n\(s)\n```\n"
        }

        // Fallback for non-strict JSON (comments, trailing commas, etc.).
        let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return "# \(title)\n\n```json\n\(raw)\n```\n"
    }
}
