# Doc2Md

A lightweight macOS app that converts documents to Markdown. Just drag and drop.

![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![macOS](https://img.shields.io/badge/macOS-13.0+-blue) ![License](https://img.shields.io/badge/license-MIT-green)

## Supported Formats

| Format | Extension | Method |
|--------|-----------|--------|
| Word (modern) | `.docx` | XML/SAX streaming parser |
| Word (legacy) | `.doc` | NSAttributedString |
| PDF | `.pdf` | PDFKit |
| PowerPoint (modern) | `.pptx` | XML/SAX streaming parser |
| PowerPoint (legacy) | `.ppt` | NSAttributedString |
| ZIP archive | `.zip` | Batch convert all supported files inside |

## Features

- **Zero dependencies** — no Pandoc, no Python, no Homebrew packages
- **Native macOS app** — built with SwiftUI
- **Drag and drop** — just drop files onto the window
- **Handles large files** — SAX streaming parser, no memory issues
- **Batch conversion** — drop a ZIP containing multiple documents
- **Output location** — `.md` files are saved next to the original file

## Usage

1. Open Doc2Md
2. Drag `.docx`, `.doc`, `.pdf`, `.pptx`, `.ppt`, or `.zip` files onto the drop zone
3. Converted `.md` files appear in the same folder as the originals

## Build

```bash
# Clone
git clone https://github.com/qtwhat/doc2md.git
cd doc2md

# Build with script
bash build.sh

# Or open in Xcode
open Doc2Md.xcodeproj
```

Requires **Xcode 15+** and **macOS 13.0+**.

## DOCX Conversion Details

The DOCX converter preserves:
- Headings (H1–H6)
- **Bold**, *italic*, ~~strikethrough~~
- Ordered and unordered lists
- Tables
- Hyperlinks

## License

MIT
