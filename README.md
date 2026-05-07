# Doc2Md

> A native macOS app that converts documents to Markdown. Drag, drop, done.
>
> 原生 macOS 文档转 Markdown 工具。拖入即转换，零依赖，性能优先。

[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org)
[![macOS](https://img.shields.io/badge/macOS-14.0+-blue.svg)](https://www.apple.com/macos/)
[![Universal](https://img.shields.io/badge/Universal-Apple%20Silicon%20%7C%20Intel-lightgrey.svg)]()
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

---

## Why Doc2Md?

把任意常见格式（Word、PDF、PowerPoint、Excel、EPUB、邮件……）一键转成干净的 Markdown，方便丢进 LLM、知识库、笔记系统。

- **零依赖** — 不需要 Pandoc、Python、Homebrew、LibreOffice。下载即用。
- **15 种格式覆盖** — 从办公文档到电子书到 Outlook 邮件。
- **性能优先** — 秒级启动，大文件 SAX 流式解析不爆内存。
- **PDF 真 OCR** — Vision 框架，支持中英日韩，可调精度，支持自定义纠错词典。
- **可定制 Pipeline** — 内置 3 个预设（通用 / 专利-3GPP / 技术规范），亦可自定义流水线。
- **完全离线** — 所有处理在本机完成，不向外发送文档。

适合：研究人员、技术写作者、需要把文档喂给 LLM 的工程师、做知识管理的重度笔记用户。

---

## Supported Formats · 支持格式

**15 种** — 覆盖办公文档、电子书、邮件、富文本、纯文本。

| Category | Format | Extension | Engine |
|---|---|---|---|
| Office | Word (modern) | `.docx` | XML/SAX streaming parser |
| Office | Word (legacy) | `.doc` | NSAttributedString |
| Office | PowerPoint (modern) | `.pptx` | XML/SAX streaming parser |
| Office | PowerPoint (legacy) | `.ppt` | NSAttributedString |
| Office | Excel | `.xlsx` | Multi-sheet → Markdown tables |
| Office | PDF | `.pdf` | PDFKit + Vision OCR |
| Rich Text | RTF | `.rtf` | NSAttributedString |
| Rich Text | HTML | `.html`, `.htm` | Streaming XHtml → Markdown |
| OpenDocument | ODT | `.odt` | XML parser |
| Ebook | EPUB | `.epub` | HTML chapters → single / per-chapter |
| Ebook | Mobi / Kindle | `.mobi`, `.azw`, `.azw3` | PalmDOC decode |
| Email | EML (Outlook / Apple Mail export) | `.eml` | RFC 5322 + multipart |
| Plain Text | Text / Markdown | `.txt`, `.md`, `.markdown` | Pass-through / normalize |
| Archive | ZIP | `.zip` | Batch convert every supported file inside |

输出文件 `.md` 默认与原文件放在同目录。EPUB 可选「单文件 / 每章分离」两种模式。

---

## Quick Start · 快速使用

1. 启动 **Doc2Md**
2. 把文件（或一组文件）拖到主窗口的拖放区
3. 同目录下出现 `.md`

按 **⌘ ,** 打开「设置」调节 OCR 精度、Pipeline 预设、EPUB 输出模式等。

---

## Configuration · 配置

所有配置集中在 Settings 窗口（`⌘ ,`），共 **4 个 Tab**：

| Tab | 内容 |
|---|---|
| **OCR** | PDF 渲染精度（2x / 3x / 4x）· 识别语言（主/副）· 标点模式（半角 / 全角 / 自动）· 纠错词典开关 |
| **Pipeline** | 预设方案 · 步骤级开关 · 输出格式（markdown / claims / metadata / report）· 自定义预设管理 |
| **EPUB** | 输出模式：单文件 vs 每章分离 |
| **纠错词典** | `~/Documents/Doc2Md/ocr_corrections.json` 字典统计 · 打开 · 重新加载 |

主窗口刻意保持纯粹（仅拖放区 + 转换列表），不订阅任何全局 singleton — 改设置不会触发主窗口重绘。

### Pipeline Presets · 流水线预设

| Preset | 适用场景 | 输出 |
|---|---|---|
| **Default** | 通用文档 → Markdown | `markdown` |
| **Patent-3GPP** | 专利 / 3GPP 标准文稿 | `markdown` + `claims` + `metadata` + `report` |
| **Technical-Spec** | 技术规范，无需提取 claims / metadata | `markdown` |

自定义预设位于 `~/Documents/Doc2Md/pipelines/*.json`，在 Settings → Pipeline 中管理。

### OCR Correction Dictionary · OCR 纠错词典

PDF OCR 启用后，会自动加载 `~/Documents/Doc2Md/ocr_corrections.json` 作为词典对识别结果做后处理替换。词典文件被监控，编辑后重新转换即生效。格式：

```json
{
  "corrections": {
    "wrongword": "correctword",
    "識別錯字": "正确字"
  }
}
```

---

## Build · 构建

```bash
# Clone
git clone https://github.com/qtwhat/doc2md.git
cd doc2md

# Quick build script
bash build.sh

# Or open in Xcode
open Doc2Md.xcodeproj
```

**要求**：Xcode 15+，macOS 14.0+。
**产物**：Universal Binary（Apple Silicon + Intel）。

---

## Architecture · 架构要点

为什么这个 App 启动快、配置不卡顿：

- **主窗口不订阅任何 singleton** — `ContentView` 只持有一个 `@StateObject ConversionViewModel`。Pipeline / OCR / EPUB 设置都在子 View 内 `@ObservedObject`，粒度最小。
- **Settings 窗口懒加载** — SwiftUI `Settings` Scene 在用户首次按 `⌘ ,` 前完全不实例化。
- **磁盘 I/O 全部后台化** — `PipelineManager` / `ExternalCorrections` 启动时的目录创建、默认预设写入、JSON 解析、文件监控全部在 `DispatchQueue.global(qos: .utility)`；`@Published` 写入回主线程。
- **Lightweight Picker tags** — Pipeline 预设 Picker 绑定到 `String`（预设名）而非整个 `PipelineConfig` 结构体，SwiftUI diff 廉价。
- **No sidebar / no AppKit material** — 曾尝试 `NavigationSplitView` + `NSVisualEffectView` 侧边栏，首次展开动画卡顿严重，已整体移除并改为菜单/Settings 模式。

### Markdown Paragraph Spec · 段落规范

转换器统一在段落末尾输出 `\n\n`（空白行）。Markdown 规范中单 `\n` 是 soft break，会让相邻段落塌陷成一段（这是 v1.2 之前的已知 bug，v1.3 修复）。代价：连续 bullet 变成 loose list（项之间空一行），仍是合法 Markdown，且 PostProcessor 会把 3+ 空行折叠为 2，无过度空白。

### DOCX Details

The DOCX converter preserves:
- Headings (H1–H6)
- **Bold**, *italic*, ~~strikethrough~~
- Ordered and unordered lists (with nesting via `numbering.xml`)
- Tables (rendered as Markdown tables)
- Hyperlinks

### EML Details

The EML converter handles:
- RFC 5322 headers, including folded continuation lines
- RFC 2047 encoded-words（`=?UTF-8?B?...?=` / `=?UTF-8?Q?...?=`），任意 IANA charset
- `multipart/*` 按 boundary 切片，优先 `text/html`，回落 `text/plain`，支持嵌套
- Content-Transfer-Encoding：base64 / quoted-printable / 7bit / 8bit
- 输出：`# Subject` + `From / To / Cc / Date` 元信息块 + 正文 Markdown

---

## What's New · 最近更新

- **v1.3.0** — 新增 `.eml` 邮件支持；修复段落分隔被吞导致的多段塌陷问题。
- **v1.2.0** — 配置全部收归 Settings 窗口；启动时间 10s+ → 秒级。
- **v1.1.0** — 多格式扩展：6 → 14；新增 EPUB / MOBI / XLSX / RTF / HTML / ODT；引入 Pipeline 系统与 PDF OCR。
- **v1.0.0** — 初始版本：DOCX / DOC / PDF / PPTX / PPT / ZIP。

完整记录见 [CHANGELOG.md](CHANGELOG.md)。

---

## Roadmap · 计划中

按需求度排：

- [ ] 列表项检测增强：处理使用段落样式（"List Paragraph"）但缺 `numPr` 的 DOCX
- [ ] 双栏 PDF 版面识别质量改进（ColumnReconstructor v2）
- [ ] 表格中 OCR 单元格还原
- [ ] 图片提取 / 内嵌为 Markdown 图片引用
- [ ] CLI 模式（`doc2md input.pdf -o output.md`）便于脚本批处理
- [ ] 公证版本 `.dmg` 直接下载

欢迎在 Issues 区提需求与 bug。

---

## Contributing · 贡献

Pull requests 欢迎。提交前请：

1. 确保 `xcodebuild -project Doc2Md.xcodeproj -scheme Doc2Md -configuration Release build` 通过
2. 新增格式时同步：`ConversionEngine.supportedExtensions`、`ConversionEngine.convert(url:)` switch、`ContentView` 拖放提示与图标、`pbxproj` 三处条目（PBXBuildFile / PBXFileReference / Sources phase）
3. 转换器输出 Markdown 段落以 `\n\n` 分隔
4. 在 `CHANGELOG.md` 记录变更

---

## License

[MIT](LICENSE) — 可自由用于商业与个人用途。
