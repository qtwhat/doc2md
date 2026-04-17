# Doc2Md

A lightweight macOS app that converts documents to Markdown. Just drag and drop.

![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![macOS](https://img.shields.io/badge/macOS-14.0+-blue) ![License](https://img.shields.io/badge/license-MIT-green)

轻量级 macOS 文档转 Markdown 工具 · 拖入即转换 · 性能优先 · 零依赖

---

## Supported Formats · 支持的格式

**14 种格式**，涵盖办公文档、电子书、富文本、纯文本。

| Category | Format | Extension | Method |
|---|---|---|---|
| Office | Word (modern) | `.docx` | XML/SAX streaming parser |
| Office | Word (legacy) | `.doc` | NSAttributedString |
| Office | PDF | `.pdf` | PDFKit + Vision OCR |
| Office | PowerPoint (modern) | `.pptx` | XML/SAX streaming parser |
| Office | PowerPoint (legacy) | `.ppt` | NSAttributedString |
| Office | Excel | `.xlsx` | Multi-sheet → Markdown tables |
| Rich Text | RTF | `.rtf` | NSAttributedString |
| Rich Text | HTML | `.html`, `.htm` | XHtml → Markdown |
| OpenDocument | ODT | `.odt` | XML parser |
| Ebook | EPUB | `.epub` | HTML chapters → single / per-chapter |
| Ebook | Mobi / Kindle | `.mobi`, `.azw`, `.azw3` | PalmDOC decode |
| Plain Text | Text / Markdown | `.txt`, `.md`, `.markdown` | Pass-through / normalize |
| Archive | ZIP | `.zip` | Batch convert every supported file inside |

---

## Features · 功能

- **Zero dependencies** — no Pandoc, no Python, no Homebrew packages
- **Native macOS app** — SwiftUI, Universal Binary (Apple Silicon + Intel)
- **Drag & drop** — drop files or folders onto the window
- **Handles large files** — SAX streaming parsers, no memory bloat
- **Batch conversion** — drop a ZIP containing multiple documents
- **PDF OCR** — Vision-based, adjustable render scale, custom correction dictionary
- **Pipeline presets** — Default / Patent-3GPP / Technical-Spec, or build your own
- **Performance first** — sub-second launch, idle main window stays non-reactive to settings
- **Output location** — `.md` files are saved next to the original file

---

## Usage · 使用方式

1. 打开 **Doc2Md**
2. 把文件（或多个文件）拖到拖放区
3. 转换后的 `.md` 与原文件放在同目录

配置（可选）：按 **⌘ ,** 打开「设置」窗口。

---

## Settings · 设置

所有可调参数集中在 Settings 窗口（`⌘ + ,`），共 **4 个 Tab**：

| Tab | 内容 |
|---|---|
| **OCR** | PDF 渲染精度（2x / 3x / 4x）· 识别语言（主/副）· 标点模式 · OCR 纠错词典开关 |
| **Pipeline** | 预设方案 · 步骤级开关 · 输出格式（markdown / claims / metadata / report）· 自定义预设管理 |
| **EPUB** | 输出模式：单文件 vs 每章分离 |
| **纠错词典** | `~/Documents/Doc2Md/ocr_corrections.json` 的字典统计、打开、重新加载 |

---

## Pipeline Presets · 流水线预设

内置 3 个预设，满足最常见的场景：

| Preset | 场景 | 输出 |
|---|---|---|
| **Default** | 通用文档 → Markdown | `markdown` |
| **Patent-3GPP** | 专利 / 3GPP 标准文稿 | `markdown` + `claims` + `metadata` + `report` |
| **Technical-Spec** | 技术规范、无需提取 claims / metadata | `markdown` |

自定义预设存放于 `~/Documents/Doc2Md/pipelines/*.json`，在 Settings → Pipeline 中管理。

---

## Build · 构建

```bash
# Clone
git clone https://github.com/qtwhat/doc2md.git
cd doc2md

# Build with script
bash build.sh

# Or open in Xcode
open Doc2Md.xcodeproj
```

**要求**：Xcode 15+，macOS 14.0+。

---

## Architecture Notes · 架构笔记

几个决定性能表现的关键点：

- **Main window does not observe global singletons** — 拖放 + 列表，仅 `ConversionViewModel` 一个 `@StateObject`。改设置不会触发主窗口重绘。
- **Settings 窗口懒加载** — SwiftUI `Settings` Scene 在首次 `⌘ ,` 前完全不实例化。
- **磁盘 I/O 全部后台化** — `PipelineManager` / `ExternalCorrections` 启动时的目录创建、默认预设写入、JSON 解析、文件监控全部在 `DispatchQueue.global(qos: .utility)`；`@Published` 写入回主线程。
- **Lightweight Picker tags** — Pipeline 预设 Picker 绑定到 `String`（预设名）而非整个 `PipelineConfig` 结构体，SwiftUI diff 更廉价。
- **No sidebar / no AppKit material** — 曾尝试过 `NavigationSplitView` + `NSVisualEffectView` sidebar，首次展开动画卡顿严重，已整体移除。

---

## DOCX Conversion Details

The DOCX converter preserves:
- Headings (H1–H6)
- **Bold**, *italic*, ~~strikethrough~~
- Ordered and unordered lists
- Tables
- Hyperlinks

## Changelog

详见 [CHANGELOG.md](CHANGELOG.md)。最近一次大更新（v1.2.0）将所有配置集中到 Settings 窗口，启动时间从 10s+ 降至秒级。

## License

MIT
