<p align="right"><a href="README.md">简体中文</a> · <a href="README.en.md">English</a></p>

<p align="center">
  <img src="docs/icon.png" width="160" alt="Doc2Md icon">
</p>

<h1 align="center">Doc2Md</h1>

<p align="center">A macOS tool that converts common document formats into Markdown. Drag a file onto the main window, or invoke it from the command line, and get a <code>.md</code> file.</p>

<p align="center">
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-5.9-F05138.svg?logo=swift&logoColor=white" alt="Swift"></a>
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14.0+-007AFF.svg?logo=apple&logoColor=white" alt="macOS"></a>
  <img src="https://img.shields.io/badge/Universal-Apple%20Silicon%20%7C%20Intel-666.svg" alt="Universal">
  <a href="#supported-formats"><img src="https://img.shields.io/badge/formats-31-brightgreen.svg" alt="Formats"></a>
  <a href="CHANGELOG.md"><img src="https://img.shields.io/badge/release-v1.6.0-blueviolet.svg" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License"></a>
</p>

## Table of Contents

- [What this tool does](#what-this-tool-does)
- [Supported formats](#supported-formats) (and how file-type auto-detection works)
- [OCR](#ocr) (Vision framework + post-processing)
- [How to use it](#how-to-use-it) (GUI / CLI)
- [Configuration](#configuration)
- [Build](#build)
- [Compared to Microsoft markitdown](#compared-to-microsoft-markitdown)
- [Architecture notes](#architecture-notes) (parser internals, paragraph rules, dual-mode CLI)
- [Recent releases](#recent-releases) · [Packaging a release](#packaging-a-release) · [Roadmap](#roadmap) · [Contributing](#contributing) · [Icon](#icon)

---

## What this tool does

Converts Word, PowerPoint, Excel, PDF, EPUB, email, images, CSV, and Jupyter Notebook files into Markdown. Common scenarios:

- Pre-processing material before pasting it into ChatGPT, Claude, or similar LLMs
- Organising files into Markdown-based note systems like Obsidian or Logseq
- Pre-processing for a personal knowledge base or RAG pipeline
- Pulling text out of scans and screenshots (PDF and image inputs run OCR)

The tool is a single `.app` bundle. It does not require Python, Pandoc, Homebrew, LibreOffice, or any other external environment. All processing happens locally. Documents are never uploaded.

The most often compared tool is Microsoft's [markitdown](https://github.com/microsoft/markitdown), but the two have different goals. markitdown is a Python library plus CLI, mostly used inside LLM data pipelines; Doc2Md is a native macOS app plus an embedded CLI, mostly used for ad-hoc desktop conversions. OCR is where they diverge the most: markitdown does OCR via GPT-4o or Azure (online, billed per call), while Doc2Md uses the macOS Vision framework (offline, free). Doc2Md v1.5 went through markitdown's converter list and added the formats it had that we didn't. The full comparison is at the end.

---

## Supported formats

31 file extensions covered.

| Category | Format | Extension | Engine |
|---|---|---|---|
| Office | Word (modern) | `.docx` | XML/SAX streaming parser |
| Office | Word (legacy) | `.doc` | NSAttributedString |
| Office | PowerPoint (modern) | `.pptx` | XML/SAX streaming parser |
| Office | PowerPoint (legacy) | `.ppt` | NSAttributedString |
| Office | Excel | `.xlsx` | One Markdown table per sheet |
| Office | PDF | `.pdf` | PDFKit text layer with Vision OCR fallback |
| Rich text | RTF | `.rtf` | NSAttributedString |
| Rich text | HTML | `.html`, `.htm` | Streaming XHtml to Markdown |
| OpenDocument | ODT | `.odt` | XML parser |
| Ebook | EPUB | `.epub` | Single file or per-chapter output |
| Ebook | Mobi / Kindle | `.mobi`, `.azw`, `.azw3` | PalmDOC decoder |
| Email | EML (Apple Mail / Gmail / Thunderbird exports) | `.eml` | RFC 5322 + multipart |
| Email | MSG (Outlook exports) | `.msg` | OLE Compound + MAPI properties |
| Image | PNG / JPEG / HEIC / TIFF / BMP / GIF / WebP | `.png` `.jpg` `.jpeg` `.heic` `.heif` `.tiff` `.tif` `.bmp` `.gif` `.webp` | Vision OCR + EXIF metadata |
| Data | CSV / TSV | `.csv`, `.tsv` | Quote-aware parser to Markdown table |
| Data | JSON | `.json` | Pretty-print with sorted keys |
| Data | XML | `.xml` | XMLDocument pretty-print |
| Notebook | Jupyter | `.ipynb` | nbformat v4 cells to markdown + fenced code |
| Plain text | Text / Markdown | `.txt`, `.md`, `.markdown` | Pass-through with newline cleanup |
| Archive | ZIP | `.zip` | Unzip and batch-convert every supported file inside |

The output `.md` is written next to the source file by default. For EPUB you can choose "single file" or "one file per chapter" in Settings.

### File-type detection

Doc2Md does not rely on the extension alone. When you open a file it reads the first 16 bytes and matches them against a built-in signature table:

| Header bytes | Inferred type |
|---|---|
| `25 50 44 46` (`%PDF`) | PDF |
| `50 4B 03 04` (`PK\x03\x04`) | ZIP family (incl. .docx / .pptx / .xlsx / .epub) |
| `D0 CF 11 E0 A1 B1 1A E1` | OLE family (incl. .doc / .xls / .ppt / .msg) |
| `89 50 4E 47` (`\x89PNG`) | PNG |
| `FF D8 FF` | JPEG |
| `47 49 46 38` (`GIF8`) | GIF |
| `42 4D` (`BM`) | BMP |
| `49 49 2A 00` / `4D 4D 00 2A` | TIFF |
| `ftyp` box at offset 4, brand `heic` / `mif1` / etc. | HEIC |
| `52 49 46 46` plus `WEBP` at offset 8 | WebP |
| `7B 5C 72 74 66` (`{\rtf`) | RTF |

This is implemented entirely in `Doc2Md/Converters/FileTypeDetector.swift` (about 60 lines of Swift). No dependency on the `file` command, libmagic, `magika` (Google's ML file classifier, which is what markitdown uses), or any other external library. As a result:

- Files without an extension still work (e.g., a `report` downloaded from a Linux server with no `.pdf` suffix)
- Files with a deliberately wrong extension still work (e.g., a PDF renamed to `notes.txt`)
- The detector does not "correct" extensions that are already accurate. ZIP family formats (`.docx` / `.pptx` / `.xlsx` / `.epub`) share the same magic bytes because they are all ZIPs underneath, and OLE family formats (`.doc` / `.xls` / `.ppt` / `.msg`) share their own magic. In these cases the extension is the more specific signal, so the detector keeps it

> [!NOTE]
> Even a `report.pdf` someone renamed to `report.txt` will be recognised as PDF and OCR'd correctly. A file downloaded from a browser without any extension can be dropped in directly.

---

## OCR

PDF and image inputs go through the system's Vision framework (`VNRecognizeTextRequest`). Key properties:

- Fully offline, runs on the local Neural Engine or GPU
- Supports Chinese, English, Japanese, Korean, Arabic, and other scripts
- macOS 14+ exposes `automaticallyDetectsLanguage`. When enabled, Vision picks the recognition model based on the dominant script in the image. So a Chinese-majority document is not run through the English model and turned into garbage like `+.*=` or `òmēA#П` (this was a real bug before v1.4). The option is on by default in Settings

> [!IMPORTANT]
> If you used a version before v1.4 and changed the OCR primary language manually, double-check that Settings → OCR → "Automatic language detection" is still on. Fresh installs default to on.

After OCR, the text goes through:

- **Layout reconstruction**: the first page of a multi-column PDF is run through `ColumnReconstructor` to preserve reading order across columns
- **Paragraph bracket fixing**: Vision often misreads the closing `]` in paragraph numbers like `[0001]` as `1`, `)`, `|`, or drops it entirely. `PostProcessor` patches them with a few regexes
- **Punctuation normalisation**: full-width or half-width punctuation depending on the primary language (full-width for Chinese, half-width for English)
- **External correction dictionary**: write a set of `{"misread": "correct"}` pairs into `~/Documents/Doc2Md/ocr_corrections.json` and they are applied automatically on every run. The file is watched, so edits take effect on the next conversion without restarting

Comparison to markitdown on this point: markitdown does no OCR on PDFs (it relies on `pdfminer` / `pdfplumber` to scrape the text layer, so scanned PDFs simply fail), and its image converter uses GPT-4o to generate a caption rather than extract text. To run actual OCR through markitdown you need to install the separate `markitdown-ocr` plugin and configure an OpenAI client. Doc2Md ships all of this as the default behaviour.

---

## How to use it

### GUI

1. Launch Doc2Md
2. Drag one or more files into the drop zone in the main window
3. The `.md` shows up next to the source

Press `⌘ ,` to open Settings. Changes apply immediately, no restart needed.

### CLI

The same app binary doubles as a command-line tool. Symlink it somewhere on your `PATH`:

```bash
ln -s /Applications/Doc2Md.app/Contents/MacOS/Doc2Md /usr/local/bin/doc2md
```

The CLI grammar mirrors [markitdown's CLI](https://github.com/microsoft/markitdown#command-line), so switching between the two tools doesn't require relearning:

```bash
doc2md report.docx                  # writes report.md next to the source
doc2md report.docx -o out.md        # writes to a specific path
doc2md report.docx -o -             # writes to stdout, pipe-friendly
doc2md notes.pdf -o - | head -50
doc2md *.docx                       # batch convert
doc2md mail.msg -o -                # convert an Outlook message to stdout

cat report.docx | doc2md -i docx    # read from stdin (-i is required for extension hint)

doc2md --list-formats               # list supported extensions
doc2md --version
doc2md --help
```

> [!TIP]
> The CLI and the GUI are the **same binary**. The symlink only makes it easier to type `doc2md` instead of the full path. OCR language, Pipeline preset, and correction dictionary settings are shared between the two: whatever you change in the GUI takes effect in the CLI immediately.

The implementation is called "single-binary dual-mode". `Doc2MdApp.init()` inspects the launch arguments: if the first argument is anything other than `-psn_...` (Finder passes that when you double-click), control jumps to `CLIDispatcher`, the conversion runs synchronously, and the process exits. SwiftUI is never started, so the dock icon never appears.

---

## Configuration

Everything tunable lives in the Settings window (`⌘ ,`). No hand-edited `~/.config/doc2md.yaml` file.

### OCR tab

- **Automatic language detection**: on by default. Keep it on unless you have a specific reason. When off, the manual language pickers below take effect
- **Primary language, Secondary language**: only used in manual mode. Controls which recognition model Vision prefers
- **PDF render scale**: 2x / 3x / 4x. Controls the rasterisation scale when rendering PDF pages for OCR. Higher means more accurate OCR but slower conversion. 3x is fine for most uses
- **Punctuation mode**: half-width / full-width / auto. Auto picks based on the primary language (full-width for Chinese, half-width for English)
- **Enable OCR correction dictionary**: toggles application of `ocr_corrections.json`

### Pipeline tab

Three built-in presets:

| Preset | When to use | Output |
|---|---|---|
| Default | General document to Markdown | markdown |
| Patent-3GPP | Patent documents, 3GPP standards | markdown + claims + metadata + report |
| Technical-Spec | Technical specs, skips claims / metadata extraction | markdown |

Custom presets live in `~/Documents/Doc2Md/pipelines/*.json` and appear in the picker once you save them. Below the picker is a list of step toggles (OCR, column reconstruction, dictionary correction, quality report, structured output).

### EPUB tab

Two output modes:

- **Single file**: the whole book is merged into one `.md`
- **Per chapter**: a folder named after the book, with one `chapter-NN.md` per chapter plus an `index.md` as table of contents

### Correction dictionary tab

Shows how many rules are loaded from `~/Documents/Doc2Md/ocr_corrections.json` and provides "Reload" and "Open in Finder" buttons. The file format:

```json
{
  "corrections": {
    "wrongword": "correctword",
    "識別錯字": "正确字"
  }
}
```

---

## Build

```bash
git clone https://github.com/qtwhat/doc2md.git
cd doc2md
bash build.sh
# or
open Doc2Md.xcodeproj
```

Requires Xcode 15+ and macOS 14.0+. The output is a Universal Binary (Apple Silicon and Intel).

---

## Compared to Microsoft markitdown

[Microsoft markitdown](https://github.com/microsoft/markitdown) solves a very similar problem. Doc2Md was developed independently, but in v1.5 we went through markitdown's converter list and added the formats it had that we lacked (`.msg`, CSV, JSON, XML, IPYNB, image EXIF, magic-byte detection). This section documents the relationship so you can pick the right tool.

### What v1.5 picked up from markitdown

| Lesson | How Doc2Md implements it |
|---|---|
| `.msg` (Outlook OLE email) support | Hand-written OLE Compound Document parser plus MAPI Property Tag reader, same approach as markitdown's `_outlook_msg_converter.py` |
| Image EXIF metadata block | Uses macOS's built-in `CGImageSource`, vs markitdown's `exiftool` external dependency |
| CSV, JSON, XML, IPYNB as first-class light-structured data formats | One independent converter each, mirroring markitdown's coverage |
| File-type detection via magic bytes | A 60-line Swift signature table, vs markitdown's `magika` neural-network classifier |
| Markdown paragraphs separated by `\n\n` | markitdown does `re.sub(r"\n{3,}", "\n\n", ...)` at the output stage; Doc2Md emits `\n\n` directly in every converter |
| CLI flag naming (`-o`, `-i`, `--list-formats`) | Aligned, so users can switch between tools without relearning |

### Where Doc2Md and markitdown differ

| Dimension | markitdown | Doc2Md |
|---|---|---|
| OCR path | OpenAI GPT-4o or Azure DI / CU. Online, billed per call, documents leave the machine | macOS Vision framework. Offline, free |
| OCR multilingual | Depends on the underlying LLM | Vision auto-detects the dominant script, including CJK and mixed scripts |
| OCR post-processing | None | PostProcessor + ColumnReconstructor + external correction dictionary |
| Email coverage | `.msg` only | `.msg` plus `.eml` |
| EPUB output | Whole book merged | Whole book or per-chapter split |
| MOBI / AZW / AZW3 | Not supported | Supported |
| Deployment | `pip install`, needs Python 3.10+ and a virtualenv | Drag `.app` into `/Applications/` |
| Platform | Linux, Windows, macOS | macOS 14+ |
| PDF multi-column reading order | `pdfminer` / `pdfplumber` directly, no column awareness | `ColumnReconstructor` restores reading order |
| Web sources | YouTube transcripts, Wikipedia, Bing search results, RSS feeds | Not covered, out of scope |
| Audio transcription | `audio-transcription` optional dependency (wav / mp3) | Out of scope |
| Video transcription | Supported via Azure CU | Out of scope |
| Embeddable library | `import markitdown`, core scenario | No equivalent |
| Plugin system | Python entry_points, community plugins like `markitdown-ocr` | macOS sandbox app cannot offer equivalent mechanism |

### Which to pick

- **Use markitdown** if you run batch jobs on a Linux server, are already inside a Python data pipeline, or need to ingest YouTube / Wikipedia / RSS content
- **Use Doc2Md** if you work day-to-day on macOS, care about document privacy (don't want to send content to OpenAI or Azure), prefer drag-and-drop, or need to process scanned Chinese documents (OCR runs locally on Vision)

---

## Architecture notes

A few design choices that keep startup fast and the settings UI responsive:

- The main-window view layer does not hold any global singleton. `ContentView` only owns a single `@StateObject ConversionViewModel`. Pipeline / OCR / EPUB settings each live in their respective Settings sub-pages as `@ObservedObject`. Changing a setting does not invalidate the main window
- The Settings window is lazy. SwiftUI's `Settings` Scene is not instantiated until the user first hits `⌘ ,`, so there is no cost on the startup path
- All disk I/O on the startup path is moved off the main thread. `PipelineManager` and `ExternalCorrections` do their first-run work (directory creation, default preset writes, JSON parsing, file watchers) on `DispatchQueue.global(qos: .utility)`, with `@Published` writes dispatched back to main
- Picker selections bind to `String` (preset name) rather than the `PipelineConfig` struct itself. SwiftUI's diff is much cheaper on lightweight value types
- The main window has no sidebar and no `NSVisualEffectView`-style AppKit material. An earlier version used a `NavigationSplitView` with a sidebar material, but first-frame layout was visibly stuttering, so it was removed entirely

### Markdown paragraph rule

Every converter ends a paragraph with `\n\n` (one blank line). The Markdown spec requires a blank line between paragraphs; a single `\n` is a soft break, which renderers (GitHub, Obsidian, Typora, VS Code, etc.) treat as an in-paragraph line break that collapses adjacent paragraphs into one block. Before v1.2 `DocxConverter` and `AttributedStringToMarkdown` emitted single `\n`, so multi-paragraph output looked merged. v1.3 fixed this. The cost is that consecutive bullets get a blank line between them (loose list), which is still valid Markdown. `PostProcessor.cleanWhitespace` collapses runs of 3+ blank lines back to 2, so the output never gets excessive whitespace.

> [!IMPORTANT]
> When writing a new converter, paragraphs must end with `\n\n`, never a single `\n`. Otherwise any spec-compliant renderer will collapse them. `PostProcessor.cleanWhitespace` is a safety net, not a license.

### DOCX parsing

`Doc2Md/Converters/DocxConverter.swift`. XML/SAX streaming parser. Does not read the entire XML into memory, so it handles hundreds of MB without blowing the stack. Preserves:

- H1 through H6 headings
- Bold, italic, strikethrough
- Ordered and unordered lists, including nesting via `numbering.xml`
- Paragraphs styled with `ListParagraph` / `ListBullet` / `ListNumber` etc. even when they lack an inline `<w:numPr>` binding (v1.6 added this; previously these paragraphs rendered as plain text)
- Tables to Markdown tables
- Hyperlinks
- Embedded images: image relationships are extracted from `_rels/document.xml.rels`, `word/media/*` is copied to a sidecar `<basename>_assets/` directory, and the SAX parser inserts `![](assets/image1.png)` references at the `<a:blip r:embed="rIdN">` site

> [!NOTE]
> When a DOCX contains embedded images, the output is accompanied by a `<basename>_assets/` directory next to the `.md`. If you don't want the images, use the CLI's stdout mode (`-o -`); image extraction is skipped because stdout cannot reference local files.

### EML parsing

`Doc2Md/Converters/EmlConverter.swift`. Handles RFC 5322:

- Folded header continuation lines are joined back
- RFC 2047 encoded-words (`=?UTF-8?B?...?=` or `=?UTF-8?Q?...?=`) decoded for arbitrary IANA charsets
- `multipart/*` bodies split by boundary, with a `text/html` preference and a fallback to `text/plain`. Nested multipart is supported
- Content-Transfer-Encoding handled: base64, quoted-printable, 7bit, 8bit
- Output: `# Subject` plus a From / To / Cc / Date block, followed by the body Markdown

### MSG parsing

`Doc2Md/Converters/MsgConverter.swift`. `.msg` files are OLE Compound File Binary (CFB) containers holding a set of MAPI property streams. The converter embeds a minimal CFB reader (~250 lines) for v3 files (512-byte sectors):

- DIFAT and FAT chains
- mini-FAT (for streams smaller than 4 KB)
- Linear directory-entry scan (no red-black tree walk required because we look streams up by name)

Then it reads MAPI properties by Property Tag name:

| Property ID | Meaning |
|---|---|
| 0037 | Subject |
| 0C1A + 0C1F | Sender Name + Sender Email |
| 0E04 | DisplayTo |
| 0E03 | DisplayCc |
| 1000 | PR_BODY (plain-text body) |
| 1013 | PR_BODY_HTML (HTML body) |
| 007D | TRANSPORT_MESSAGE_HEADERS (raw RFC 5322 headers, used to extract the Date line) |

HTML body is preferred and routed through `XHtmlToMarkdown`; it falls back to plain text. Output mirrors the EML format.

### CSV parsing

`Doc2Md/Converters/CsvConverter.swift`. Hand-written, quote-aware:

- Handles embedded commas and embedded newlines
- `""` escapes a single `"` inside a quoted field
- Delimiter auto-detection: `.tsv` forces `\t`; for `.csv`, it samples the first 5 lines and picks `;` if semicolons outnumber commas (European convention), otherwise `,`

Output is a Markdown table. Cells containing `|` get the pipe escaped to `\|`, and embedded newlines become `<br>` to keep the table layout intact.

### IPYNB parsing

Reads `cells` per nbformat v4:

- `markdown` cells: raw text
- `code` cells: wrapped in a fenced block, using `metadata.kernelspec.language` as the fence language (defaulting to `python`)
- `raw` cells: raw text
- Outputs are skipped (images and DataFrame outputs are awkward to round-trip into Markdown)

### Image metadata

`Doc2Md/Converters/MetadataExtractor.swift` reads four dictionaries from `CGImageSource`:

- TIFF: Make, Model, Artist, Copyright, Software
- EXIF: DateTimeOriginal, LensModel, FocalLength, Aperture, ISO, ExposureTime
- GPS: GPSPosition, GPSAltitude
- IPTC: Title, Description, Keywords

These are rendered as a two-column Markdown table and placed before the OCR text (with a `---` separator between them). If OCR finds no text at all, the metadata still gets written, which is useful for archival purposes.

---

## Recent releases

- **v1.6.0**: DOCX `ListParagraph` style recognition (fixes earlier bullet-list loss); DOCX embedded image extraction to `<basename>_assets/`; ColumnReconstructor v2 (covers all PDF pages with false-positive guards); OCR table reconstruction (medical reports and similar grids now become Markdown tables); `release.sh` for packaging `.dmg` with optional notarization
- **v1.5.0**: caught up with markitdown on `.msg` / CSV / TSV / JSON / XML / IPYNB / image EXIF / magic-byte detection; added CLI
- **v1.4.0**: OCR support for 10 image formats (PNG / JPG / HEIC / TIFF / BMP / GIF / WebP, etc.); fixed the default-language bug that made Chinese images OCR into garbage
- **v1.3.0**: added `.eml` email support; fixed paragraph collapse in DOCX / DOC / RTF
- **v1.2.0**: consolidated all settings into the Settings window; startup time dropped from 10s+ to sub-second
- **v1.1.0**: expanded from 6 formats to 14
- **v1.0.0**: initial release with DOCX / DOC / PDF / PPTX / PPT / ZIP

Full log in [CHANGELOG.md](CHANGELOG.md).

---

## Packaging a release

`release.sh` handles the release flow:

```bash
./release.sh                                    # build + dmg + SHA-256 only
DEVELOPER_ID="Developer ID Application: ..." \
    ./release.sh                                # also codesigns
NOTARY_PROFILE=mydev DEVELOPER_ID="..." \
    ./release.sh                                # also notarizes and staples
```

One-time notarization setup (full steps in the script's comment block):

```bash
xcrun notarytool store-credentials mydev \
    --apple-id you@example.com \
    --team-id YOUR_TEAM_ID \
    --password <app-specific-password>
```

The output is in `build/release/Doc2Md-<version>.dmg`, with a matching `.sha256` checksum file beside it.

---

## Roadmap

- Embedded image extraction in PPTX and EPUB (currently only DOCX is implemented)
- Further refinement of multi-column PDF reading order (the v2 false-positive guards may be too conservative on some layouts)

---

## Contributing

Before submitting a PR, please make sure:

1. `xcodebuild -project Doc2Md.xcodeproj -scheme Doc2Md -configuration Release build` passes
2. If you are adding a new format, sync these locations:
   - `ConversionEngine.supportedExtensions`
   - The switch in `ConversionEngine.convert(url:)`
   - The switch in `ConversionEngine.convertToMarkdown(url:)` (the CLI string path)
   - The drop-zone hint text and icon in `ContentView`
   - The three pbxproj entries (PBXBuildFile, PBXFileReference, Sources phase)
3. Converters emit Markdown paragraphs separated by `\n\n`
4. Update `CHANGELOG.md`

---

## Icon

<img src="docs/icon.png" width="120" align="left" hspace="20" alt="Doc2Md icon">

The black cat peeking out from behind the `.md` placard in the app icon was generated by ChatGPT. If you find it charming too, feel free to drop a star on the repo.

<br clear="left">

---

## License

[MIT](LICENSE)
