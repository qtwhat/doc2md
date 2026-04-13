import Foundation

struct MarkdownWriter {
    static func write(markdown: String, nextTo originalURL: URL, customName: String? = nil) throws -> URL {
        let name = customName ?? originalURL.deletingPathExtension().lastPathComponent
        let outputURL = originalURL.deletingLastPathComponent()
            .appendingPathComponent(name)
            .appendingPathExtension("md")
        try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }
}
