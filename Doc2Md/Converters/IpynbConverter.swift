import Foundation

enum IpynbConverterError: LocalizedError {
    case readFailed(String)
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .readFailed(let msg): return "ipynb 读取失败: \(msg)"
        case .invalidFormat:       return "ipynb 格式无效（缺少 cells 字段）"
        }
    }
}

// MARK: - Converter
//
// Jupyter Notebook (.ipynb) → Markdown.
//
// Schema (nbformat v4):
//   { "cells": [ { "cell_type": "markdown|code|raw", "source": [...], "outputs": [...] } ] }
//
// source can be a String or [String]; we normalize both.
//
// Output rules:
//   - markdown cell  → raw text
//   - code cell      → fenced block with language from notebook metadata
//                      (default "python")
//   - raw cell       → raw text
//   - outputs are skipped by default (notebook outputs are often huge and
//     contain images / DataFrames that don't round-trip to Markdown well)

struct IpynbConverter {
    func convert(url: URL) throws -> String {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw IpynbConverterError.readFailed(error.localizedDescription) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cells = json["cells"] as? [[String: Any]] else {
            throw IpynbConverterError.invalidFormat
        }

        // Notebook language → default code-block fence language
        let language: String = {
            if let meta = json["metadata"] as? [String: Any],
               let kernelspec = meta["kernelspec"] as? [String: Any],
               let lang = kernelspec["language"] as? String {
                return lang
            }
            return "python"
        }()

        let title = url.deletingPathExtension().lastPathComponent
        var md = "# \(title)\n\n"

        for cell in cells {
            let type = cell["cell_type"] as? String ?? "raw"
            let text = sourceText(cell["source"])
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            switch type {
            case "markdown":
                md += text
                if !md.hasSuffix("\n\n") {
                    md += md.hasSuffix("\n") ? "\n" : "\n\n"
                }
            case "code":
                md += "```\(language)\n\(text)\n```\n\n"
            case "raw":
                md += text + "\n\n"
            default:
                break
            }
        }

        return md
    }

    /// Notebook cell `source` is either a single string or an array of
    /// strings (one per line, newlines included).
    private func sourceText(_ raw: Any?) -> String {
        if let arr = raw as? [String] { return arr.joined() }
        if let s = raw as? String { return s }
        return ""
    }
}
