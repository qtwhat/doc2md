# 更新日志

本项目的所有显著变更都记录在此文件中。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

## [1.3.0] – 2026-05-01

### Added

- **EML 邮件格式支持** — 新增 `.eml` → Markdown 转换。覆盖：
  - RFC 5322 头部解析（含 folded headers / RFC 2047 encoded-word 解码，支持 `=?UTF-8?B?...?=` 和 `=?UTF-8?Q?...?=`）
  - `multipart/*` 走 boundary 切片，优先 `text/html`，回落 `text/plain`，支持嵌套 multipart
  - Content-Transfer-Encoding 完整解码：`base64` / `quoted-printable` / `7bit` / `8bit`
  - HTML body 复用现有 `XHtmlToMarkdown`；plain text 段落感知（保留空白行段落分隔，单换行视为软换行合并）
  - 输出格式：`# Subject` 顶部 + `From / To / Cc / Date` 元信息块 + `---` 分隔线 + 正文 Markdown

### Fixed

- **段落分隔丢失（关键 bug）** — DocxConverter / DOC / RTF / PPT legacy 转换链原本在段落末尾仅输出 `\n`，被 Markdown 渲染器视为软换行（soft break），导致**多个段落塌陷为一段**。修复后每段以 `\n\n` 结尾，符合 Markdown 段落分隔规范，在 GitHub / Obsidian / VS Code / Typora 等渲染器中正确分段。
  - 影响文件：`DocxConverter.swift`、`AttributedStringToMarkdown.swift`
  - 副作用：连续 bullet 项变为 "loose list"（项间空一行）—— 仍为合法 Markdown，且 `cleanupMarkdown` / `PostProcessor.cleanWhitespace` 保留 3+ 空行折叠为 2，无过度空白
  - 设计取舍：选择"激进分段"而非"保守合段"，因为合并段落是语义损失（不可逆），而 loose list 仅是渲染样式差异

### Changed

- 主窗口拖放区提示文字增加 `.eml`
- 支持格式总数：14 → **15**

---

## [1.2.0] – 2026-04-17

### 架构重构：性能优先 · 配置集中

本次重构的目标是让 App 启动瞬间可用、主窗口绝对纯粹。

### Changed

- **主窗口回归最简结构** — `ContentView` 仅保留「拖放区 + 转换列表」两层 `VStack`，不再持有任何全局 singleton 的 `@ObservedObject`，设置变更不会触发主窗口重绘。
- **所有配置集中到 Settings 窗口**（`⌘ + ,`）。Settings 仅在用户首次打开时才实例化，启动路径零成本。
- **Settings 窗口重组为 4 个 Tab**：
  - **OCR** — PDF 渲染精度（2x/3x/4x）、识别语言（主/副）、标点模式、OCR 纠错开关
  - **Pipeline** — 预设方案选择（Default / Patent-3GPP / Technical-Spec）、步骤级开关、输出格式、自定义预设管理
  - **EPUB** — 输出模式（单文件 / 每章分离）
  - **纠错词典** — 字典统计、打开 JSON、重新加载

### Removed

- **侧边栏（NavigationSplitView / SidebarPanel）** — AppKit `NSVisualEffectView` + `NSSplitView` 首次 layout 是展开动画卡顿的根源，整体移除。
- **工具栏下拉菜单** — 此前与右侧 Inspector 存在功能重复，全部删除。
- **文件夹监听（Folder Watcher）** — 低频场景，从 UI 下线，减少主界面负担。
- **菜单栏 `CommandMenu("配置")`** — 尝试过的中间方案，最终统一收归 Settings 窗口。

### Performance

- **启动时间从 10s+ 降至秒级**：
  - `PipelineManager.init()` 的磁盘 I/O（创建目录 / 写入 3 个默认预设 JSON / 读取 / 解析）改为 `DispatchQueue.global(qos: .utility)` 后台执行；`@Published` 写入回主线程。
  - `ExternalCorrections.init()` 的 `reload()` 与 `startMonitoring()` 同样挪至后台队列。
- **Picker tag 优化**：Pipeline 预设 Picker 的 selection 绑定改为轻量 `String`（预设名），替代整个 `PipelineConfig` 结构体，SwiftUI diff 成本大幅降低。

---

## [1.1.0] – 2026-Q1

### 多格式扩展

从 6 种格式扩展到 **14 种**，覆盖主流办公、富文本、电子书、纯文本全谱。

### Added

- **电子书**：EPUB（HTML 章节 → Markdown，支持整本 / 分章输出）、MOBI / AZW / AZW3
- **表格**：XLSX（多 sheet → 多个 Markdown 表格）
- **富文本**：RTF、HTML / HTM
- **纯文本**：TXT、MD / Markdown（直接透传 / 规整）
- **OpenDocument**：ODT
- **Pipeline 系统**：可配置的多步骤转换流水线，内置 3 个预设（Default / Patent-3GPP / Technical-Spec），支持自定义预设 JSON
- **PDF OCR 增强**：Vision 框架识别、可调渲染精度、主/副语言、标点模式、外部纠错词典（`~/Documents/Doc2Md/ocr_corrections.json`）
- **列重建器（ColumnReconstructor）**：针对双栏 / 多栏 PDF 的版面还原
- **结构化输出**：Patent-3GPP 预设可输出 claims、metadata、质量报告

---

## [1.0.0] – 初始版本

### Added

- 原生 SwiftUI macOS 应用，拖放即转换
- 支持 6 种格式：`.docx` / `.doc` / `.pdf` / `.pptx` / `.ppt` / `.zip`
- DOCX：XML/SAX 流式解析器，保留标题、加粗、斜体、删除线、有序/无序列表、表格、超链接
- PDF：基于 PDFKit 的文本提取
- 零依赖：无 Pandoc、无 Python、无 Homebrew
- ZIP 批量转换：解压并递归转换 ZIP 中所有支持的文件
- 输出位置：`.md` 与原文件同目录

---

[1.3.0]: #130--2026-05-01
[1.2.0]: #120--2026-04-17
[1.1.0]: #110--2026-q1
[1.0.0]: #100--初始版本
