<p align="right"><a href="README.md">简体中文</a> · <a href="README.en.md">English</a></p>

<p align="center">
  <img src="docs/icon.png" width="160" alt="Doc2Md icon">
</p>

<h1 align="center">Doc2Md</h1>

<p align="center">一个把 macOS 上的常见文档转成 Markdown 的工具。拖一个文件到主窗口，或者从命令行调用，输出一份 <code>.md</code>。</p>

<p align="center">
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-5.9-F05138.svg?logo=swift&logoColor=white" alt="Swift"></a>
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14.0+-007AFF.svg?logo=apple&logoColor=white" alt="macOS"></a>
  <img src="https://img.shields.io/badge/Universal-Apple%20Silicon%20%7C%20Intel-666.svg" alt="Universal">
  <a href="#支持的格式"><img src="https://img.shields.io/badge/formats-31-brightgreen.svg" alt="Formats"></a>
  <a href="CHANGELOG.md"><img src="https://img.shields.io/badge/release-v1.6.0-blueviolet.svg" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License"></a>
</p>

## 目录

- [这个工具用来做什么](#这个工具用来做什么)
- [支持的格式](#支持的格式)（文件类型自动识别的实现）
- [OCR](#ocr)（Vision 框架 + 后处理）
- [怎么用](#怎么用)（GUI / CLI）
- [配置](#配置)
- [构建](#构建)
- [与 Microsoft markitdown 的对照](#与-microsoft-markitdown-的对照)
- [架构说明](#架构说明)（解析器细节、段落规范、双模式 CLI）
- [最近的更新](#最近的更新) · [发布打包](#发布打包) · [计划中](#计划中) · [贡献](#贡献) · [图标](#图标)

---

## 这个工具用来做什么

把 Word、PowerPoint、Excel、PDF、EPUB、邮件、图片、CSV、Jupyter Notebook 这些格式转换成 Markdown 文件。常见使用场景：

- 把资料喂给 ChatGPT、Claude 这类 LLM 之前先转成纯文本
- 整理资料进 Obsidian、Logseq 等基于 Markdown 的笔记软件
- 给知识库或 RAG 系统做预处理
- 把扫描件、截图里的文字提取出来（PDF 和图片走 OCR）

工具是一个独立的 `.app` 文件，不需要安装 Python、Pandoc、Homebrew、LibreOffice 这些环境。所有转换在本机完成，文档不会被上传到任何服务器。

同类工具里最常被对比的是 Microsoft 的 [markitdown](https://github.com/microsoft/markitdown)，但定位不一样。markitdown 是 Python 库加 CLI，主要给 LLM 数据流水线用；Doc2Md 是 macOS 原生 App 加内嵌 CLI，主要给桌面端日常转换用。OCR 路径上两者的差别最大：markitdown 通过 GPT-4o 或 Azure 提供 OCR（联网、按调用计费），Doc2Md 用 macOS 自带的 Vision 框架（离线、免费）。Doc2Md v1.5 系统对比过 markitdown 的 converter 列表，把它有而我们缺的几项格式补齐了，详细对照在文末。

---

## 支持的格式

目前覆盖 31 种文件扩展名。

| 类别 | 格式 | 扩展名 | 实现 |
|---|---|---|---|
| Office | Word（新版） | `.docx` | XML/SAX 流式解析 |
| Office | Word（旧版） | `.doc` | NSAttributedString |
| Office | PowerPoint（新版） | `.pptx` | XML/SAX 流式解析 |
| Office | PowerPoint（旧版） | `.ppt` | NSAttributedString |
| Office | Excel | `.xlsx` | 每个 sheet 转一张 Markdown 表 |
| Office | PDF | `.pdf` | PDFKit 文本层 + Vision OCR fallback |
| 富文本 | RTF | `.rtf` | NSAttributedString |
| 富文本 | HTML | `.html`, `.htm` | 流式 XHtml 转 Markdown |
| OpenDocument | ODT | `.odt` | XML 解析 |
| 电子书 | EPUB | `.epub` | 章节 HTML 合并或分章 |
| 电子书 | Mobi / Kindle | `.mobi`, `.azw`, `.azw3` | PalmDOC 解码 |
| 邮件 | EML（Apple Mail / Gmail / Thunderbird 导出） | `.eml` | RFC 5322 + multipart |
| 邮件 | MSG（Outlook 导出） | `.msg` | OLE Compound + MAPI properties |
| 图片 | PNG / JPEG / HEIC / TIFF / BMP / GIF / WebP | `.png` `.jpg` `.jpeg` `.heic` `.heif` `.tiff` `.tif` `.bmp` `.gif` `.webp` | Vision OCR + EXIF 元数据 |
| 数据 | CSV / TSV | `.csv`, `.tsv` | quote-aware 解析转 Markdown 表 |
| 数据 | JSON | `.json` | 排序+缩进打印 |
| 数据 | XML | `.xml` | XMLDocument 美化 |
| Notebook | Jupyter | `.ipynb` | nbformat v4 cells 转 markdown + fenced code |
| 纯文本 | Text / Markdown | `.txt`, `.md`, `.markdown` | 透传 / 规整换行 |
| 压缩包 | ZIP | `.zip` | 解压后批量转换里面所有支持的文件 |

转换后的 `.md` 默认写在原文件旁边的同目录。EPUB 在 Settings 里可以选「整本一个文件」或者「每章一个文件，放到一个文件夹里」。

### 文件类型识别

不依赖扩展名一种来源。打开文件时，先读头部 16 个字节，跟内置的签名表对比：

| 头部字节 | 推断格式 |
|---|---|
| `25 50 44 46` (`%PDF`) | PDF |
| `50 4B 03 04` (`PK\x03\x04`) | ZIP 系列（含 .docx / .pptx / .xlsx / .epub） |
| `D0 CF 11 E0 A1 B1 1A E1` | OLE 系列（含 .doc / .xls / .ppt / .msg） |
| `89 50 4E 47` (`\x89PNG`) | PNG |
| `FF D8 FF` | JPEG |
| `47 49 46 38` (`GIF8`) | GIF |
| `42 4D` (`BM`) | BMP |
| `49 49 2A 00` / `4D 4D 00 2A` | TIFF |
| 偏移 4 是 `ftyp`，brand 是 `heic` / `mif1` 等 | HEIC |
| `52 49 46 46` 加偏移 8 的 `WEBP` | WebP |
| `7B 5C 72 74 66` (`{\rtf`) | RTF |

这部分实现完全在 `Doc2Md/Converters/FileTypeDetector.swift` 里，约 60 行 Swift 代码，不依赖 `file` 命令、libmagic、`magika`（Google 的 ML 文件分类器，markitdown 用的就是它）或者任何外部库。所以：

- 文件没有扩展名也能识别（比如从 Linux 下载下来的 `report` 没有 `.pdf` 后缀）
- 扩展名故意改错也能识别（比如把 PDF 改名成 `notes.txt`）
- 检测器不会乱改正确的扩展名。ZIP 系列里 `.docx` / `.pptx` / `.xlsx` / `.epub` 共享同一个魔数（它们本质都是 ZIP），OLE 系列里 `.doc` / `.xls` / `.ppt` / `.msg` 也共享同一个魔数。这种情况下扩展名才是更准确的信息，所以检测器把 ZIP-family 和 OLE-family 视为「魔数和扩展名都正常」的情况，保留用户给的扩展名

> [!NOTE]
> 即使 `report.pdf` 被人改成 `report.txt`，拖进去仍然能识别为 PDF 并正常 OCR；从浏览器下载下来缺扩展名的文件直接拖也行。

---

## OCR

PDF 和图片走 macOS 系统自带的 Vision 框架（`VNRecognizeTextRequest`）。这个框架的关键能力：

- 完全离线，在本机的 Neural Engine 或 GPU 上跑
- 支持中、英、日、韩、阿拉伯文等多种脚本
- macOS 14+ 提供 `automaticallyDetectsLanguage` 选项。打开之后 Vision 自己判断这张图主要是什么脚本，然后用对应的识别模型。所以一张以中文为主的体检单不会被英文模型识别成乱码（v1.4 之前出现过这个 bug，体现是中文段落变成 `+.*=`、`òmēA#П` 这类符号串）。这个选项在 Settings 里默认是开的

> [!IMPORTANT]
> 如果你升级前装过 v1.4 之前的版本并改过 OCR 主语言，建议进 Settings → OCR 确认「自动语言检测」是打开的。新装的用户默认就是开的。

OCR 跑完之后会经过这几步后处理：

- **排版重建**：双栏 PDF 的第一页用 `ColumnReconstructor` 还原阅读顺序，避免左栏和右栏的句子交错
- **段落括号修复**：Vision 经常把 `[0001]` 这种段落标号末尾的 `]` 读成 `1`、`)`、`|` 或者完全丢掉。PostProcessor 用几条正则修回去
- **标点规范化**：根据主语言决定全角还是半角。中文文档输出全角逗号、句号、引号，英文文档输出半角
- **自定义纠错词典**：`~/Documents/Doc2Md/ocr_corrections.json` 里写一组 `{"識別錯字": "正确字"}`，每次 OCR 自动套用。改了 JSON 不需要重启，词典文件被监控，下次转换就生效

这套链路对比 markitdown：markitdown 在 PDF 上完全不做 OCR（依赖 `pdfminer` / `pdfplumber` 抽文本层，扫描件直接失败），在图片上靠 `_image_converter.py` 的 GPT-4o 描述（属于「写一段图片说明」，不是文字提取）。要在 markitdown 里做 PDF OCR 需要装独立的 `markitdown-ocr` 插件并配置 OpenAI client。Doc2Md 把这些做成内置默认。

---

## 怎么用

### GUI 模式

1. 启动 Doc2Md
2. 把一个或多个文件拖到主窗口的拖放区
3. 转换后的 `.md` 出现在原文件旁边

按 `⌘ ,` 打开 Settings 窗口调节参数。设置改完不需要重启。

### CLI 模式

App 二进制本身可以当命令行工具用。先装一个短名字方便从终端调用：

```bash
ln -s /Applications/Doc2Md.app/Contents/MacOS/Doc2Md /usr/local/bin/doc2md
```

> [!TIP]
> CLI 和 GUI 用的是**同一个可执行文件**，没有额外的 binary 要装。symlink 只是为了从终端敲 `doc2md` 而不是写全路径。GUI 里调好的 OCR 语言、Pipeline 预设、纠错词典对 CLI 立即生效。

用法语义对齐 [markitdown CLI](https://github.com/microsoft/markitdown#command-line)，这样用户从一边切到另一边不用重新学：

```bash
doc2md report.docx                  # 在原文件旁边写 report.md
doc2md report.docx -o out.md        # 输出到指定路径
doc2md report.docx -o -             # 输出到 stdout，可以接管道
doc2md notes.pdf -o - | head -50    # pipe-friendly
doc2md *.docx                       # 批量转换
doc2md mail.msg -o -                # Outlook 邮件转换并打印到 stdout

cat report.docx | doc2md -i docx    # 从 stdin 读，要用 -i 指明扩展名

doc2md --list-formats               # 列出支持的扩展名
doc2md --version
doc2md --help
```

实现方式叫「单二进制双模式」，意思是 GUI 和 CLI 是同一个可执行文件。`Doc2MdApp.init()` 检查启动参数：如果第一个不是 `-psn_...`（Finder 双击 App 时会传这种参数），就直接进 `CLIDispatcher` 跑完后 `exit`，SwiftUI 永远不启动，dock 图标也不出现。所以 GUI 和 CLI 共用同一份 OCR 设置、Pipeline 预设、纠错词典。在 GUI 里调好的参数，命令行立即生效。

---

## 配置

所有可调参数都在 Settings 窗口里，按 `⌘ ,` 打开。没有 `~/.config/doc2md.yaml` 这种需要手编的配置文件。

### OCR 标签页

- **自动语言检测**：默认开。建议保持开，关掉之后才会用下面的语言选项
- **主语言、副语言**：手动模式下生效，决定 Vision 识别时优先用哪个脚本的模型
- **PDF 渲染精度**：2x / 3x / 4x，控制 PDF 转栅格图时的倍率。倍数越高 OCR 越准但速度越慢。一般 3x 够用
- **标点模式**：半角 / 全角 / 自动。自动模式下根据主语言来选（中文用全角，英文用半角）
- **启用 OCR 纠错词典**：开关 `ocr_corrections.json` 的应用

### Pipeline 标签页

内置三个预设：

| 预设 | 用途 | 输出格式 |
|---|---|---|
| Default | 通用文档转 Markdown | markdown |
| Patent-3GPP | 专利、3GPP 标准文稿 | markdown + claims + metadata + report |
| Technical-Spec | 技术规范，跳过 claims / metadata 提取 | markdown |

也可以在 `~/Documents/Doc2Md/pipelines/*.json` 里自己写预设，写完出现在选项里。下面有一个 toggles 区域可以单独开关某一步（OCR、列重建、纠错词典、质量报告、结构化输出）。

### EPUB 标签页

两种输出模式：

- **单文件**：整本书合并成一个 `.md`
- **每章分离**：以书名命名一个文件夹，每章一个 `chapter-NN.md`，再加一个 `index.md` 作目录

### 纠错词典标签页

显示 `~/Documents/Doc2Md/ocr_corrections.json` 当前装了多少条规则，提供「重新加载」「在 Finder 里打开」两个按钮。词典格式：

```json
{
  "corrections": {
    "wrongword": "correctword",
    "識別錯字": "正确字"
  }
}
```

---

## 构建

```bash
git clone https://github.com/qtwhat/doc2md.git
cd doc2md
bash build.sh
# 或者
open Doc2Md.xcodeproj
```

要求 Xcode 15+，macOS 14.0+。产物是 Universal Binary（同时支持 Apple Silicon 和 Intel）。

---

## 与 Microsoft markitdown 的对照

[Microsoft markitdown](https://github.com/microsoft/markitdown) 跟 Doc2Md 解决的问题重合度很高。Doc2Md 起初是独立开发的，v1.5 时系统比对过两边的 converter 列表，把 markitdown 已经覆盖而我们缺的几项（`.msg` / CSV / JSON / XML / IPYNB / 图片 EXIF / magic-byte 检测）一次性补齐。这一节把对照写明，方便你判断该用哪一个。

### v1.5 从 markitdown 那里学到的几样东西

| 学到的点 | Doc2Md 的实现方式 |
|---|---|
| `.msg`（Outlook OLE 邮件）支持 | 自己写了一个 OLE Compound Document 解析器加 MAPI Property Tag 读取，跟 markitdown 的 `_outlook_msg_converter.py` 同路径 |
| 图片 EXIF 元数据块 | 用 macOS 自带的 `CGImageSource`，对标 markitdown 的 `exiftool` 外部依赖路径 |
| CSV、JSON、XML、IPYNB 这四类轻量结构化数据 | 各做一个独立 converter，markitdown 同样把它们列为基础格式 |
| 文件类型用魔数检测 | 自己写了一张签名表（约 60 行 Swift），对应 markitdown 用 `magika` 神经网络分类器 |
| Markdown 段落用 `\n\n` 分隔 | markitdown 在输出阶段统一 `re.sub(r"\n{3,}", "\n\n", ...)` 规范化，Doc2Md 在每个 converter 里直接输出 `\n\n` |
| CLI 接口的命名（`-o`、`-i`、`--list-formats`） | 完全对齐，便于用户在两个工具间切换 |

### Doc2Md 与 markitdown 的差异

| 维度 | markitdown | Doc2Md |
|---|---|---|
| OCR 路径 | OpenAI GPT-4o 或 Azure DI / CU。联网、按调用计费、文档过云 | macOS Vision 框架。离线、免费 |
| OCR 多语言 | 取决于背后 LLM 的能力 | Vision 自动识别主脚本，CJK 与混排也准 |
| OCR 后处理 | 无 | PostProcessor + ColumnReconstructor + 外置纠错词典 |
| 邮件覆盖 | 仅 `.msg` | `.msg` 加 `.eml` |
| EPUB 输出 | 整本合成一个文件 | 整本或按章拆分两种模式 |
| MOBI / AZW / AZW3 | 不支持 | 支持 |
| 部署方式 | `pip install`，需要 Python 3.10+ 和虚拟环境 | 把 `.app` 拖进 `/Applications/` |
| 平台 | Linux、Windows、macOS | macOS 14+ |
| PDF 双栏识别 | `pdfminer` / `pdfplumber` 直接抽，不处理双栏顺序 | `ColumnReconstructor` 还原阅读顺序 |
| Web 资源转换 | 支持 YouTube 字幕、Wikipedia、Bing 搜索结果、RSS feed | 不支持，定位不符 |
| 音频转写 | `audio-transcription` 可选依赖（wav / mp3） | 不在范围内 |
| 视频转写 | Azure CU 路径支持 | 不在范围内 |
| 作为库嵌入 | `import markitdown`，核心场景 | 没有等价物 |
| 插件系统 | Python entry_points，社区有 `markitdown-ocr` 等扩展 | macOS sandbox App 没法支持等价机制 |

### 怎么选

- **用 markitdown**：你在 Linux 服务器上做批处理、已经在 Python 数据 pipeline 里、需要转 YouTube / Wikipedia 等 Web 资源
- **用 Doc2Md**：你日常在 macOS 上工作、重视文档隐私（不想把内容传给 OpenAI 或 Azure）、需要拖放体验、或者要处理大量扫描中文文档（OCR 走本地 Vision）

---

## 架构说明

启动快、设置不卡顿的几个关键决定：

- 主窗口的视图层不持有任何全局 singleton。`ContentView` 只有一个 `@StateObject ConversionViewModel`。Pipeline、OCR、EPUB 各自的设置都封在 Settings 的子页里，作为 `@ObservedObject`。改设置不会触发主窗口重绘
- Settings 窗口懒加载。SwiftUI 的 `Settings` Scene 在用户第一次按 `⌘ ,` 之前不会实例化，启动路径上没有它的成本
- 启动路径上的磁盘 I/O 全部挪到后台队列。`PipelineManager` 和 `ExternalCorrections` 第一次初始化时要做的事（创建目录、写入默认预设 JSON、读取并解析 JSON、注册文件监听）全部在 `DispatchQueue.global(qos: .utility)` 跑，`@Published` 写入再调度回主线程
- Picker 的 selection 绑定到 `String`（预设名）而不是 `PipelineConfig` 结构体。SwiftUI 对轻量类型的 diff 快得多
- 主窗口没有 sidebar，没有 `NSVisualEffectView` 这种需要 GPU pipeline 的 AppKit 控件。早期版本用过 `NavigationSplitView` 加 sidebar material，但首次展开动画明显卡顿，最后整体移除

### Markdown 段落规范

每个 converter 在段落末尾输出 `\n\n`（一个空白行）。Markdown 规范规定段落分隔需要空白行，单 `\n` 是 soft break，会被渲染器（GitHub、Obsidian、Typora、VS Code 等）当成段内换行而合并。v1.2 之前 `DocxConverter` 和 `AttributedStringToMarkdown` 只输出 `\n`，所以多个段落看起来塌成一段。v1.3 修掉这个问题。代价是连续 bullet 项之间会多一个空行（loose list），但仍是合法 Markdown，PostProcessor 的 `cleanWhitespace` 把 3 个以上的连续空行折叠回 2 个，所以不会出现过度的空白。

> [!IMPORTANT]
> 写新 converter 时段落必须以 `\n\n` 结尾，不要用单 `\n`。否则在任何合规渲染器里都会塌段。`PostProcessor.cleanWhitespace` 是兜底，不是免责声明。

### DOCX 解析

`Doc2Md/Converters/DocxConverter.swift`。XML/SAX 流式解析器，不把整个 XML 读进内存，可以处理百 MB 级文件不爆栈。保留：

- H1 到 H6 标题
- 加粗、斜体、删除线
- 有序、无序列表，包括 `numbering.xml` 里的嵌套层级
- 段落样式名 `ListParagraph` / `ListBullet` / `ListNumber` 等：即使没有内联 `<w:numPr>` 绑定，也会输出成 bullet 或 numbered list（v1.6 加，修了之前这种段落被输出成普通文本的 bug）
- 表格转 Markdown 表格
- 超链接
- 嵌入图片：从 `_rels/document.xml.rels` 抽出 image relationship，把 `word/media/*` 复制到 `<basename>_assets/` 旁路目录，SAX parser 识别 `<a:blip r:embed="rIdN">` 后在段落里插入 `![](assets/image1.png)`

> [!NOTE]
> 转 DOCX 时如果包含嵌入图片，输出旁边会多一个 `<basename>_assets/` 文件夹。如果不想要图片，用 CLI 的 stdout 模式（`-o -`）会跳过图片提取，只输出文本 Markdown。

### EML 解析

`Doc2Md/Converters/EmlConverter.swift`。按 RFC 5322 处理：

- 拼接折叠的 header 续行
- 解码 RFC 2047 encoded-word（`=?UTF-8?B?...?=` 或 `=?UTF-8?Q?...?=`），任意 IANA charset
- `multipart/*` 按 boundary 切分，优先 `text/html`，回落 `text/plain`，支持嵌套 multipart
- Content-Transfer-Encoding 解码：base64、quoted-printable、7bit、8bit
- 输出：`# Subject` 加上 `From / To / Cc / Date` 元信息块，加上正文 Markdown

### MSG 解析

`Doc2Md/Converters/MsgConverter.swift`。`.msg` 是 OLE Compound File Binary（CFB）容器，里面藏着一组 MAPI 属性流。Converter 内嵌一个最小 CFB 解析器（约 250 行），处理 v3 格式（512 字节 sector）：

- DIFAT 与 FAT 链
- mini-FAT（小于 4096 字节的小流）
- 目录项的线性扫描（不走红黑树，因为我们只需要按名字查流）

读到流之后按 MAPI Property Tag 名解析：

| Property ID | 含义 |
|---|---|
| 0037 | Subject |
| 0C1A + 0C1F | Sender Name + Sender Email |
| 0E04 | DisplayTo |
| 0E03 | DisplayCc |
| 1000 | PR_BODY（纯文本正文） |
| 1013 | PR_BODY_HTML（HTML 正文） |
| 007D | TRANSPORT_MESSAGE_HEADERS（原始 RFC 5322 头部，从这里抓 Date 行） |

优先 HTML body 走 `XHtmlToMarkdown`，回落到纯文本。输出格式与 EML 一致。

### CSV 解析

`Doc2Md/Converters/CsvConverter.swift`。手写的 quote-aware 解析器：

- 嵌入的逗号、嵌入的换行都能正确处理
- 双引号转义 `""` 还原成单个 `"`
- 分隔符自动嗅探：`.tsv` 强制用 `\t`；`.csv` 看前 5 行，分号多于逗号的话用 `;`（欧洲 CSV 习惯），否则用 `,`

输出 Markdown 表格。单元格里的 `|` 转义成 `\|`，换行转 `<br>`，避免破坏表格布局。

### IPYNB 解析

按 nbformat v4 schema 解析 `cells`：

- markdown cell 直接输出原文
- code cell 用 `metadata.kernelspec.language` 作为 fence 语言（缺省 `python`）包成 fenced block
- raw cell 直接输出原文
- outputs 跳过（图像和 DataFrame 输出难以回归 Markdown）

### 图片 metadata

`Doc2Md/Converters/MetadataExtractor.swift` 从 `CGImageSource` 抓四个 dict：

- TIFF：Make、Model、Artist、Copyright、Software
- EXIF：DateTimeOriginal、LensModel、FocalLength、Aperture、ISO、ExposureTime
- GPS：GPSPosition、GPSAltitude
- IPTC：Title、Description、Keywords

渲染成两列 Markdown 表格，插在 OCR 文本之前（中间用 `---` 分隔）。即使 OCR 没识别到任何文字，元数据仍然会被写进 `.md`，方便存档。

---

## 最近的更新

- **v1.6.0**：DOCX「List Paragraph」样式识别（修了之前 bullet 列表丢失的 bug）；DOCX 嵌入图片提取到 `<basename>_assets/`；ColumnReconstructor v2（覆盖所有 PDF 页 + false-positive 保护）；OCR 表格还原（医院检查报告这类网格能识别成 Markdown 表）；`release.sh` 打 `.dmg` 加 notarization 脚本
- **v1.5.0**：补齐 markitdown 列表里的 `.msg` / CSV / TSV / JSON / XML / IPYNB / 图片 EXIF / magic-byte 检测；加 CLI 接口
- **v1.4.0**：10 种图片格式（PNG / JPG / HEIC / TIFF / BMP / GIF / WebP 等）的 OCR 支持；修了默认 OCR 语言导致中文图片识别乱码的 bug
- **v1.3.0**：加 `.eml` 邮件支持；修 DOCX / DOC / RTF 段落塌陷的 bug
- **v1.2.0**：把所有配置入口集中到 Settings 窗口；启动时间从 10s+ 降到秒级
- **v1.1.0**：从 6 种格式扩展到 14 种
- **v1.0.0**：初始版本，DOCX / DOC / PDF / PPTX / PPT / ZIP

完整记录见 [CHANGELOG.md](CHANGELOG.md)。

---

## 发布打包

`release.sh` 处理 release 流程：

```bash
./release.sh                                    # 仅 build + dmg + SHA-256
DEVELOPER_ID="Developer ID Application: ..." \
    ./release.sh                                # 加 codesign
NOTARY_PROFILE=mydev DEVELOPER_ID="..." \
    ./release.sh                                # 加 notarytool 提交 + staple
```

Notarization 一次性配置（在脚本注释里有完整步骤）：

```bash
xcrun notarytool store-credentials mydev \
    --apple-id you@example.com \
    --team-id YOUR_TEAM_ID \
    --password <app-specific-password>
```

产物在 `build/release/Doc2Md-<version>.dmg`，旁边带 `.sha256` 校验和文件。

---

## 计划中

- PPTX / EPUB 也支持嵌入图片提取（目前只 DOCX 实现了）
- 双栏 PDF 阅读顺序的进一步打磨（v2 的 false-positive 保护可能在某些 layout 上过于保守）

---

## 贡献

提 PR 之前请确认：

1. `xcodebuild -project Doc2Md.xcodeproj -scheme Doc2Md -configuration Release build` 通过
2. 如果加新格式，同步改这几处：
   - `ConversionEngine.supportedExtensions`
   - `ConversionEngine.convert(url:)` 的 switch
   - `ConversionEngine.convertToMarkdown(url:)` 的 switch（CLI 单字符串路径）
   - `ContentView` 的拖放提示文字和图标
   - `pbxproj` 三处条目（PBXBuildFile、PBXFileReference、Sources phase）
3. 转换器输出的 Markdown 段落以 `\n\n` 分隔
4. 更新 `CHANGELOG.md`

---

## 图标

<img src="docs/icon.png" width="120" align="left" hspace="20" alt="Doc2Md icon">

App 图标里那只抱着 `.md` 牌子的黑猫由 [TODO: 填来源] 制作。如果你也喜欢它，可以在 issue 区给个 star。

<br clear="left">

> [!NOTE]
> 图标来源占位等你补：是 ChatGPT 4o / Midjourney / DALL-E 出的还是哪位设计师画的？把这一段替换掉就行。

---

## License

[MIT](LICENSE)
