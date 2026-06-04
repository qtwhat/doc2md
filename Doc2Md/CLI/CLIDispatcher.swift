import Foundation
import AppKit

// MARK: - CLI Dispatcher
//
// Doc2Md is a single SwiftUI binary that can also run as a CLI tool.
// Detection happens inside Doc2MdApp.init():
//
//     if let rc = CLIDispatcher.maybeRun() { exit(rc) }
//
// We exit before SwiftUI fires NSApplicationMain, so no window is created
// and the dock icon never appears. Vision OCR, NSAttributedString,
// CGImageSource, PDFKit, and Foundation all work without a running event
// loop, so the entire conversion pipeline executes synchronously.
//
// CLI grammar (modeled on Microsoft markitdown's CLI for familiarity):
//
//     doc2md INPUT [INPUT ...]              # writes <INPUT>.md next to each input
//     doc2md INPUT -o OUTPUT                # writes single output to OUTPUT
//     doc2md INPUT -o -                     # writes to stdout
//     cat INPUT.docx | doc2md -i docx       # read from stdin (requires -i hint)
//     doc2md --version
//     doc2md --help

enum CLIDispatcher {

    /// Returns nil if Doc2Md should launch its GUI normally. Returns an
    /// exit code if CLI mode was requested (caller must exit() with it).
    static func maybeRun() -> Int32? {
        let argv = CommandLine.arguments
        guard argv.count >= 2 else { return nil }
        let first = argv[1]
        // Finder passes -psn_0_NNNN (process serial number) when launching a
        // bundled app via double-click. Treat those as GUI launches.
        if first.hasPrefix("-psn_") { return nil }
        // Suppress the dock icon for CLI invocations. Must happen before any
        // AppKit drawing call; harmless if NSApp is later not used.
        NSApplication.shared.setActivationPolicy(.prohibited)
        return run(args: Array(argv.dropFirst()))
    }

    // MARK: - Argument parsing + dispatch

    private static func run(args: [String]) -> Int32 {
        var inputs: [String] = []
        var outputPath: String? = nil
        var stdinHintExt: String? = nil
        var showHelp = false
        var showVersion = false
        var listFormats = false

        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "-h", "--help":
                showHelp = true
            case "-v", "--version":
                showVersion = true
            case "--list-formats":
                listFormats = true
            case "-o", "--output":
                guard i + 1 < args.count else {
                    fputs("doc2md: -o requires an argument\n", stderr)
                    return 2
                }
                outputPath = args[i + 1]
                i += 1
            case "-i", "--input-extension":
                guard i + 1 < args.count else {
                    fputs("doc2md: -i requires an argument\n", stderr)
                    return 2
                }
                stdinHintExt = args[i + 1].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                i += 1
            default:
                if a.hasPrefix("-") {
                    fputs("doc2md: unknown option \(a)\n", stderr)
                    fputs("Try 'doc2md --help'.\n", stderr)
                    return 2
                }
                inputs.append(a)
            }
            i += 1
        }

        if showHelp { printHelp(); return 0 }
        if showVersion { print("Doc2Md \(version)"); return 0 }
        if listFormats { printFormats(); return 0 }

        // Stdin mode: no positional input, hint via -i
        if inputs.isEmpty {
            return runStdin(extensionHint: stdinHintExt, outputPath: outputPath)
        }

        // -o with multiple inputs is ambiguous unless it's stdout
        if outputPath != nil && outputPath != "-" && inputs.count > 1 {
            fputs("doc2md: -o only supports a single input (got \(inputs.count))\n", stderr)
            return 2
        }

        let engine = ConversionEngine()
        var rc: Int32 = 0
        for input in inputs {
            let url = URL(fileURLWithPath: input)
            guard FileManager.default.fileExists(atPath: url.path) else {
                fputs("doc2md: \(input): No such file\n", stderr)
                rc = 1
                continue
            }

            do {
                if let out = outputPath {
                    let md = try engine.convertToMarkdown(url: url)
                    if out == "-" {
                        FileHandle.standardOutput.write(Data(md.utf8))
                    } else {
                        try md.write(toFile: out, atomically: true, encoding: .utf8)
                    }
                } else {
                    // Default: write .md next to each input
                    let outputs = try engine.convert(url: url)
                    for o in outputs {
                        FileHandle.standardError.write(Data("wrote \(o.path)\n".utf8))
                    }
                }
            } catch {
                fputs("doc2md: \(input): \(error.localizedDescription)\n", stderr)
                rc = 1
            }
        }
        return rc
    }

    // MARK: - Stdin mode
    //
    // Buffers all of stdin into a temp file with the user-supplied extension,
    // runs the conversion, prints to stdout (or writes to outputPath), then
    // cleans up. Necessary because converters take URLs, not streams.

    private static func runStdin(extensionHint ext: String?, outputPath: String?) -> Int32 {
        guard let ext = ext, !ext.isEmpty else {
            fputs("doc2md: reading from stdin requires -i <extension> hint, e.g. -i docx\n", stderr)
            return 2
        }
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doc2md-stdin-\(getpid()).\(ext)")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let data = FileHandle.standardInput.readDataToEndOfFile()
        do {
            try data.write(to: tmpURL)
            let md = try ConversionEngine().convertToMarkdown(url: tmpURL)
            if let out = outputPath, out != "-" {
                try md.write(toFile: out, atomically: true, encoding: .utf8)
            } else {
                FileHandle.standardOutput.write(Data(md.utf8))
            }
            return 0
        } catch {
            fputs("doc2md: stdin: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    // MARK: - Help / formats

    private static let version = "1.5.0"

    private static func printHelp() {
        let text = """
        Doc2Md \(version) — Convert documents to Markdown.

        USAGE
          doc2md INPUT [INPUT ...]                Convert each, write .md beside it
          doc2md INPUT -o OUTPUT                  Write Markdown to OUTPUT
          doc2md INPUT -o -                       Write Markdown to stdout
          cat INPUT.docx | doc2md -i docx         Read from stdin (extension hint required)

        OPTIONS
          -o, --output PATH                       Output path; "-" means stdout
          -i, --input-extension EXT               Hint extension for stdin input
              --list-formats                      List supported file extensions
          -h, --help                              Show this help
          -v, --version                           Show version

        EXAMPLES
          doc2md report.docx                      # writes report.md
          doc2md photo.heic -o text.md            # OCR + EXIF metadata → text.md
          doc2md notes.pdf -o - | head -50        # pipe-friendly
          doc2md *.docx                           # batch convert
          doc2md mail.msg -o -                    # Outlook → Markdown to stdout

        Doc2Md is a macOS app; the CLI is the same binary at
        /Applications/Doc2Md.app/Contents/MacOS/Doc2Md. To install a shorter
        name, symlink it:
          ln -s /Applications/Doc2Md.app/Contents/MacOS/Doc2Md /usr/local/bin/doc2md
        """
        print(text)
    }

    private static func printFormats() {
        let sorted = ConversionEngine.supportedExtensions.sorted()
        print(sorted.joined(separator: "\n"))
    }
}
