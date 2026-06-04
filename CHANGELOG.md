# 更新日志

本项目的所有显著变更都记录在此文件中。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

## [1.6.0] – 2026-06-04

清掉 v1.5 之前 Roadmap 上的几项（音频转写暂缓）。

### Added

- **DOCX "List Paragraph" 样式识别** — Word 经常对列表段落只打 `pStyle="ListParagraph"` 这种样式名，不带 `<w:numPr>` 绑定到 numbering。之前这种段落会被输出成普通文本（用户的 3GPP 文档里 5 个「类型」bullet 全部丢失就是这个 bug 引起的）。新增 `parseListStyle()`，识别 `ListParagraph` / `ListBullet` / `ListNumber` / `BulletList` / `NumberList` 等样式名，没 numPr 时也用 `-` 或 `1.` 默认 marker。
- **DOCX 嵌入图片提取** — `DocxConverter` 新增 `assetsDir` 与 `assetsRelativePrefix` 字段。设置后从 `_rels/document.xml.rels` 抽出 image relationship，从 `word/media/*` 复制图片到 `<basename>_assets/` 旁路目录，SAX parser 识别 `<a:blip r:embed="rIdN">` 并在段落里插入 `![](assets/image1.png)`。CLI stdout 模式不抽（无法 reference 本地文件）。
- **ColumnReconstructor v2** — 之前只对 PDF 首页跑双栏检测，其余页用简单 top-to-bottom 排序。v2 让所有页都过 ColumnReconstructor，由它内部判断单/多栏；同时加了三条 false-positive 保护（>4 栏拒绝、单栏占比 >80% 拒绝、可由 `forceColumns: true` 跳过保护）。
- **OCR 表格还原** — 新文件 `Pipeline/TableDetector.swift`。扫描 Vision observations 找出网格状簇（≥3 行 × ≥2 列，列 X-center 在 4% 容差内对齐），抽出来渲染成 Markdown 表格；剩余 observation 继续走 ColumnReconstructor 出正文。PdfConverter 和 ImageConverter 共用，对你那张医院体检单的「AO 31mm / LA 35mm / IVSd 9mm / ...」这种 4 列 4 行的检测表格应该能识别成 Markdown 表格了。
- **release.sh** — 新建独立 release 打包脚本。无 cert 时跑：clean build + .dmg + SHA-256；设 `DEVELOPER_ID` 时附加 codesign；设 `NOTARY_PROFILE` 时附加 notarytool 提交 + staple。脚本里写明 notarization 一次性凭据配置流程。

### Changed

- DocxConverter 改成 `struct` mutable，加 `assetsDir` 字段
- DocxSAXParser init 新增 `imageRefs` 参数（默认空，保持向后兼容）
- PdfConverter 的 OCR 路径去掉 `simpleTextFromObservations`，统一走 ColumnReconstructor

---

## [1.5.0] – 2026-06-04

### Added

借鉴 Microsoft markitdown 的覆盖广度，补齐 6 类新格式 + 1 套基础设施 + CLI 接口。所有路径仍走本地，无任何云端依赖。

- **CLI 模式（dual-mode 单二进制）** — 新文件 `CLI/CLIDispatcher.swift`。`Doc2MdApp.init()` 检测到非 `-psn_` 命令行参数即转入 CLI，跑完直接 `exit`，SwiftUI 永不启动、dock 图标永不出现。语义对齐 markitdown CLI：
  - `doc2md INPUT [INPUT ...]` 批量转换，写 `.md` 到同目录
  - `doc2md INPUT -o OUTPUT` / `doc2md INPUT -o -` 自定义路径或 stdout
  - `cat INPUT.docx | doc2md -i docx` stdin 输入（须 `-i` 给扩展名提示）
  - `--list-formats` / `--help` / `--version`
  - 与 GUI 共用同一份 OCR / Pipeline / 纠错词典 设置
  - 新增 `ConversionEngine.convertToMarkdown(url:) throws -> String` 直返字符串（不落盘），CLI stdout 模式专用

- **Outlook `.msg` 支持** — 新文件 `Converters/MsgConverter.swift`，内嵌一个 ~250 行的 OLE Compound Document（CFB）解析器：512-byte v3 sector / FAT chain / mini-FAT / 目录线性扫描。直接读取 MAPI Property Tag stream（`__substg1.0_XXXXYYYY`）：
  - Subject (0037) / Sender (0C1A + 0C1F) / DisplayTo (0E04) / DisplayCc (0E03)
  - PR_BODY (1000) 与 PR_BODY_HTML (1013)，优先 HTML 走 `XHtmlToMarkdown`
  - PR_TRANSPORT_MESSAGE_HEADERS (007D) 中抓 `Date:` 行
  - 输出：`# Subject` + From / To / Cc / Date + 正文 Markdown
- **CSV / TSV 支持** — `Converters/CsvConverter.swift`，quote-aware 解析器（嵌入逗号、嵌入换行、`""` 转义引号），自动嗅探分隔符（`,` / `;` / `\t`），输出 Markdown 表格，单元格内的 `|` 转义、`\n` 转 `<br>`。
- **JSON 支持** — `Converters/JsonConverter.swift`，`JSONSerialization` + `.sortedKeys` + `.prettyPrinted` 输出 fenced code block，diff 稳定；解析失败回落原文输出。
- **XML 支持** — `Converters/XmlConverter.swift`，`XMLDocument` 美化输出 fenced code block，畸形回落原文。
- **Jupyter Notebook `.ipynb` 支持** — `Converters/IpynbConverter.swift`，按 nbformat v4 schema 解析：markdown cell 直出、code cell 按 kernelspec language fenced、raw cell 直出，outputs 默认跳过。
- **图片 EXIF 元数据** — 新文件 `Converters/MetadataExtractor.swift`，从 `CGImageSource` 抓取 TIFF / EXIF / GPS / IPTC：ImageSize / Make / Model / Artist / DateTimeOriginal / LensModel / FocalLength / Aperture / ISO / ExposureTime / GPSPosition / GPSAltitude / Title / Description / Keywords。即使 OCR 无文本也输出元数据（用于存档），有文本则元数据 + `---` + OCR 文本拼接。
- **文件类型 magic-byte 检测** — 新文件 `Converters/FileTypeDetector.swift`，签名表覆盖 PDF / ZIP-family / OLE-family / PNG / JPEG / GIF / BMP / TIFF / HEIC / WebP / RTF，并维护「family」表（ZIP magic 不会把 `.docx` 改写为 `.zip`，OLE magic 不会把 `.doc` 改写为 `.msg`）。`ConversionEngine.convert(url:)` 入口使用 magic 解析后的扩展名，使应用对扩展名错误或缺失的文件鲁棒。

### Changed

- 主窗口拖放区提示文字、ConversionRow 文件图标扩展覆盖（envelope / tablecells / curlybraces / function / photo）。
- 支持格式总数：25 → **31**（新增 msg / csv / tsv / json / xml / ipynb）。

### Comparison with Microsoft markitdown

| 维度 | markitdown | Doc2Md 1.5 |
|---|---|---|
| OCR | 云端 LLM（付费）或 Azure DI / CU（付费） | 本地 Vision，免费，CJK auto-detect |
| Outlook | `.msg` ✅ | `.msg` ✅ + `.eml` ✅ |
| 格式数 | ~20+ | 31 |
| EXIF | exiftool（外部依赖） | CGImageSource（内置） |
| 文件检测 | magika ML 模型 + StreamInfo | magic-byte 签名表 |
| 调度 | accepts() + priority + 插件 | 扩展名 switch（+ magic 前置解析） |
| CLI | `markitdown FILE -o OUT` | `doc2md FILE -o OUT`（同语义，dual-mode 单二进制） |

---

## [1.4.0] – 2026-05-07

### Fixed

- **OCR 中文识别失败（关键 bug）** — 默认 OCR 设置（primary=en, secondary=zh-Hans）让 Vision 以英文模型为主，对中文为主的图片产生大量乱码（如把"mm"识别为俄文 `лит`，把中文段落识别为符号串）。修复方式：启用 `VNRecognizeTextRequest.automaticallyDetectsLanguage`（macOS 13+），让 Vision 自己根据图片脚本选模型。Settings → OCR → 「自动语言检测（推荐）」**默认开启**，手动语言下拉框在自动模式下灰显但保留。

### Added

- **图片格式 OCR 支持** — 新增 `.png` / `.jpg` / `.jpeg` / `.heic` / `.heif` / `.tiff` / `.tif` / `.bmp` / `.gif` / `.webp` → Markdown，无需先转 PDF。新文件 `Converters/ImageConverter.swift`。
  - **直接走 Vision OCR**：跳过 PDF 中转，单次 `VNRecognizeTextRequest`，与 PDF OCR 共用识别语言、custom hint words、PostProcessor、ExternalCorrections、paragraph-bracket fix
  - **EXIF 朝向自动校正**：iPhone 拍照、扫描件常带非默认 orientation，CIImage `.oriented(_:)` 处理
  - **小图自动放大**：长边 < 1500px 时按 OCRRenderScale 倍率上采样（`high` 插值），改善细小字体识别
  - **输出格式**：`# {filename}` 标题 + OCR 处理后正文

### Changed

- 主窗口拖放区提示文字与图标增加图片相关条目
- 支持格式总数：15 → **25**

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

[1.6.0]: #160--2026-06-04
[1.5.0]: #150--2026-06-04
[1.4.0]: #140--2026-05-07
[1.3.0]: #130--2026-05-01
[1.2.0]: #120--2026-04-17
[1.1.0]: #110--2026-q1
[1.0.0]: #100--初始版本
