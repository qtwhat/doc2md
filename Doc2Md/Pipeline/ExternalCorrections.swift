import Foundation
import Combine

/// Loads OCR correction dictionaries from an external JSON file so users can
/// add new corrections without recompiling.
///
/// File location: `~/Documents/Doc2Md/ocr_corrections.json`
class ExternalCorrections: ObservableObject {
    static let shared = ExternalCorrections()

    let fileURL: URL
    private var fileMonitor: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.doc2md.externalCorrections", qos: .utility)

    @Published var wordReplacements: [String: String] = [:]
    @Published var patternReplacements: [(pattern: String, replacement: String, caseInsensitive: Bool)] = []
    @Published var spacedWords: [String: String] = [:]
    @Published var whitelist: Set<String> = []
    @Published var customHintWords: [String] = []

    // MARK: - Initialisation

    private init() {
        let documents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
            .appendingPathComponent("Doc2Md")
        fileURL = documents.appendingPathComponent("ocr_corrections.json")

        // Defer all disk I/O (default-file creation, JSON parse, directory
        // watcher setup) to a background queue so app launch stays snappy.
        queue.async { [weak self] in
            self?.reload()
            self?.startMonitoring()
        }
    }

    deinit {
        fileMonitor?.cancel()
    }

    // MARK: - Public API

    /// Apply all loaded corrections to the given text and return the result.
    func applyCorrections(to text: String) -> String {
        var result = text

        // 0. Built-in critical corrections (always applied regardless of external file state)
        let builtinFixes: [(String, String)] = [
            ("(c.g.", "(e.g."),
            ("c.g.,", "e.g.,"),
            ("c.g.", "e.g."),
            (" loT ", " IoT "),
            (" lOT ", " IoT "),
            ("loT ", "IoT "),
        ]
        for (wrong, correct) in builtinFixes {
            result = result.replacingOccurrences(of: wrong, with: correct)
        }

        // 1. Spaced-word corrections (do these first so later word replacements
        //    can match the joined result).
        for (broken, fixed) in spacedWords {
            result = result.replacingOccurrences(of: broken, with: fixed)
        }

        // 2. Word replacements (simple string substitution).
        for (wrong, correct) in wordReplacements {
            result = result.replacingOccurrences(of: wrong, with: correct)
        }

        // 3. Regex pattern replacements.
        for entry in patternReplacements {
            var options: NSRegularExpression.Options = []
            if entry.caseInsensitive {
                options.insert(.caseInsensitive)
            }
            guard let regex = try? NSRegularExpression(pattern: entry.pattern, options: options) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: entry.replacement)
        }

        // 4. Whitelist pass – restore any whitelisted terms that might have been
        //    accidentally altered. We do a case-sensitive check: if the original
        //    text contained the whitelisted term and the result no longer does,
        //    we leave it alone (the corrections above are deterministic so this
        //    is a safety net rather than a full undo mechanism).
        //    In practice the whitelist is used by callers to skip correction on
        //    tokens that match, so we expose it rather than enforce it here.

        return result
    }

    /// Reload corrections from disk.  If the file does not exist, a default
    /// file is created first.
    func reload() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            createDefaultFile()
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            print("[ExternalCorrections] Failed to read \(fileURL.path)")
            return
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[ExternalCorrections] Root object is not a dictionary")
                return
            }
            parseJSON(json)
        } catch {
            print("[ExternalCorrections] JSON parse error: \(error.localizedDescription)")
        }
    }

    // MARK: - Parsing

    private func parseJSON(_ json: [String: Any]) {
        // word_replacements
        if let wr = json["word_replacements"] as? [String: String] {
            DispatchQueue.main.async { self.wordReplacements = wr }
        }

        // pattern_replacements
        if let pr = json["pattern_replacements"] as? [[String: Any]] {
            let parsed: [(String, String, Bool)] = pr.compactMap { entry in
                guard let pattern = entry["pattern"] as? String,
                      let replacement = entry["replacement"] as? String else { return nil }
                let ci = entry["case_insensitive"] as? Bool ?? false
                return (pattern, replacement, ci)
            }
            DispatchQueue.main.async { self.patternReplacements = parsed }
        }

        // spaced_words
        if let sw = json["spaced_words"] as? [String: String] {
            DispatchQueue.main.async { self.spacedWords = sw }
        }

        // whitelist
        if let wl = json["whitelist"] as? [String] {
            DispatchQueue.main.async { self.whitelist = Set(wl) }
        }

        // custom_hint_words
        if let chw = json["custom_hint_words"] as? [String] {
            DispatchQueue.main.async { self.customHintWords = chw }
        }
    }

    // MARK: - Default file creation

    private func createDefaultFile() {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let defaults: [String: Any] = [
            "version": 1,

            "word_replacements": [
                "cnable": "enable",
                "cnabled": "enabled",
                "cnables": "enables",
                "cnabling": "enabling",
                "cach ": "each ",
                "reccived": "received",
                "reccive": "receive",
                "cmbodiment": "embodiment",
                "compriscs": "comprises",
                "connccted": "connected",
                "connccting": "connecting",
                "conncction": "connection",
                "Scptember": "September",
                "cnters": "enters",
                "cnter": "enter",
                "cstablish": "establish",
                "cxample": "example",
                "cxecutc": "execute",
                "cxecute": "execute",
                "cffect": "effect",
                "cfficient": "efficient",
                "cxist": "exist",
                "cvent": "event",
                "cxcept": "except",
                "bctwccn": "between",
                "bctwcen": "between",
                "detcrmine": "determine",
                "mcssage": "message",
                "nctwork": "network",
                "rcsource": "resource",
                "proccss": "process",
                "proccssor": "processor",
                "rcquest": "request",
                "rcspons": "respons",
                "rcceiv": "receiv",
                "rcport": "report",
                "rcconnect": "reconnect",
                "spccif": "specif",
                "indicatc": "indicate",
                "configurc": "configure",
                "mcthod": "method",
                "systcm": "system",
                "proccdur": "procedur",
                "Sheuzhen": "Shenzhen",
                "Shcnzhen": "Shenzhen",
                "c.g.": "e.g.",
                "c.g.,": "e.g.,",
                "loT": "IoT",
                "lOT": "IoT",
                "Chanel": "Channel"
            ],

            "pattern_replacements": [
                [
                    "pattern": "\\bconnccted\\b",
                    "replacement": "connected",
                    "case_insensitive": false
                ]
            ],

            "spaced_words": [
                "sy stem": "system",
                "net work": "network",
                "sig nal": "signal",
                "mes sage": "message",
                "re source": "resource",
                "pro cess": "process",
                "con nect": "connect",
                "dis connect": "disconnect",
                "con figure": "configure",
                "em bodiment": "embodiment"
            ],

            "whitelist": [
                "UE", "IE", "PTM", "gNB", "eNB", "NR", "LTE",
                "RRC", "PDCP", "RLC", "MAC"
            ],

            "custom_hint_words": [] as [String]
        ]

        do {
            let data = try JSONSerialization.data(
                withJSONObject: defaults,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: fileURL, options: .atomic)
            print("[ExternalCorrections] Created default file at \(fileURL.path)")
        } catch {
            print("[ExternalCorrections] Failed to create default file: \(error.localizedDescription)")
        }
    }

    // MARK: - File monitoring

    private func startMonitoring() {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // We monitor the containing directory so we also catch file creation /
        // replacement (some editors do atomic-save by writing a temp file then
        // renaming it).
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            print("[ExternalCorrections] Could not open directory for monitoring")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Small delay to let the write finish (atomic saves, etc.)
            self.queue.asyncAfter(deadline: .now() + 0.3) {
                self.reload()
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileMonitor = source
    }
}
