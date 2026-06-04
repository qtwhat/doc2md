import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = OCRSettings.shared
    @ObservedObject var pipelineManager = PipelineManager.shared
    @ObservedObject var epubSettings = EpubSettings.shared
    @ObservedObject var corrections = ExternalCorrections.shared

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ocrTab
                .tabItem { Label("OCR", systemImage: "doc.viewfinder") }
                .tag(0)

            pipelineTab
                .tabItem { Label("Pipeline", systemImage: "gearshape.2") }
                .tag(1)

            epubTab
                .tabItem { Label("EPUB", systemImage: "book") }
                .tag(2)

            correctionsTab
                .tabItem { Label("纠错词典", systemImage: "character.book.closed") }
                .tag(3)
        }
        .frame(width: 520, height: 520)
    }

    // MARK: - OCR Tab

    private var ocrTab: some View {
        Form {
            Section {
                Picker("渲染精度", selection: $settings.renderScale) {
                    ForEach(OCRRenderScale.allCases) { scale in
                        Text(scale.displayName).tag(scale)
                    }
                }
                .pickerStyle(.segmented)

                Text("更高精度 = OCR 更准确，但 PDF 转换速度更慢。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Label("PDF 渲染精度", systemImage: "scalemass")
            }

            Section {
                Toggle("自动语言检测（推荐）", isOn: $settings.automaticallyDetectsLanguage)

                Text("启用后，Vision 自动判断图片/PDF 中是中文、英文、日文、韩文还是混合脚本，选择最合适的识别模型。关闭后，使用下方手动指定的语言顺序。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("主语言（手动模式）", selection: $settings.primaryLanguage) {
                    ForEach(OCRLanguageProfile.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .disabled(settings.automaticallyDetectsLanguage)

                Picker("副语言（手动模式）", selection: Binding(
                    get: { settings.secondaryLanguage ?? .chineseSimplified },
                    set: { settings.secondaryLanguage = $0 }
                )) {
                    ForEach(OCRLanguageProfile.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .disabled(settings.automaticallyDetectsLanguage)
            } header: {
                Label("识别语言", systemImage: "globe")
            }

            Section {
                Picker("标点模式", selection: $settings.punctuationMode) {
                    ForEach(PunctuationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(punctuationHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Label("标点符号", systemImage: "textformat")
            }

            Section {
                Toggle("启用 OCR 纠错词典", isOn: $settings.enableOCRCorrection)
            } header: {
                Label("后处理", systemImage: "wand.and.stars")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Pipeline Tab

    private var pipelineTab: some View {
        Form {
            Section {
                // Bind to config.name (lightweight String) rather than the
                // full PipelineConfig struct — keeps SwiftUI's diff cheap.
                Picker("预设方案", selection: Binding(
                    get: { pipelineManager.activeConfig.name },
                    set: { newName in
                        if let match = pipelineManager.availableConfigs
                            .first(where: { $0.name == newName }) {
                            pipelineManager.activeConfig = match
                        }
                    }
                )) {
                    ForEach(pipelineManager.availableConfigs, id: \.name) { config in
                        Text(config.name).tag(config.name)
                    }
                }

                if !pipelineManager.activeConfig.description.isEmpty {
                    Text(pipelineManager.activeConfig.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Label("活动预设", systemImage: "list.bullet.rectangle")
            }

            Section {
                ForEach(Array(pipelineManager.activeConfig.steps.enumerated()), id: \.element.name) { index, step in
                    Toggle(stepDisplayName(step.name), isOn: Binding(
                        get: { step.enabled },
                        set: { newValue in
                            pipelineManager.activeConfig.steps[index].enabled = newValue
                        }
                    ))
                }
            } header: {
                Label("处理步骤", systemImage: "checklist")
            }

            Section {
                let formats = pipelineManager.activeConfig.outputFormats
                Text(formats.joined(separator: ", "))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Label("输出格式", systemImage: "doc.on.doc")
            }

            Section {
                Button("保存当前预设到 JSON") {
                    pipelineManager.saveActiveConfig()
                }
                Button("重新加载预设目录") {
                    pipelineManager.loadConfigs()
                }
                Text("预设目录：~/Documents/Doc2Md/pipelines/")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Label("预设管理", systemImage: "tray.and.arrow.down")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - EPUB Tab

    private var epubTab: some View {
        Form {
            Section {
                Picker("输出模式", selection: $epubSettings.outputMode) {
                    ForEach(EpubOutputMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Text(epubSettings.outputMode == .singleFile
                     ? "整本书合并为一个 .md 文件。"
                     : "每章单独 .md + index.md 目录，保存在以书名命名的文件夹里。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Label("EPUB 输出", systemImage: "book")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Corrections Tab

    private var correctionsTab: some View {
        Form {
            Section {
                HStack {
                    Text("词语替换")
                    Spacer()
                    Text("\(corrections.wordReplacements.count) 条")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("正则替换")
                    Spacer()
                    Text("\(corrections.patternReplacements.count) 条")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("断词修复")
                    Spacer()
                    Text("\(corrections.spacedWords.count) 条")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("白名单")
                    Spacer()
                    Text("\(corrections.whitelist.count) 个词")
                        .foregroundColor(.secondary)
                }
            } header: {
                Label("纠错词典统计", systemImage: "character.book.closed")
            }

            Section {
                Button("在编辑器中打开词典文件") {
                    let url = ExternalCorrections.shared.fileURL
                    NSWorkspace.shared.open(url)
                }

                Button("重新加载词典") {
                    ExternalCorrections.shared.reload()
                }

                Text("词典文件: ~/Documents/Doc2Md/ocr_corrections.json")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Label("操作", systemImage: "arrow.clockwise")
            }

            Section {
                Text("编辑 JSON 文件后自动重新加载。\n格式: word_replacements, pattern_replacements, spaced_words, whitelist, custom_hint_words")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Label("说明", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private var punctuationHint: String {
        switch settings.punctuationMode {
        case .halfWidth:
            return "强制将（）［］：；等全角标点转为半角，适合英文技术文档"
        case .fullWidth:
            return "保留全角标点不做转换，适合中文/日文文档"
        case .auto:
            return "根据主语言自动判断：英文→半角，中日韩→全角"
        }
    }

    private func stepDisplayName(_ name: String) -> String {
        switch name {
        case "vision_ocr": return "Vision OCR 识别"
        case "column_reconstruction": return "多栏版式重建"
        case "punctuation_normalize": return "标点符号归一化"
        case "special_char_normalize": return "特殊字符归一化"
        case "hyphen_merge": return "跨行连字符合并"
        case "dictionary_correct": return "纠错词典校正"
        case "noise_removal": return "噪声行移除"
        case "quality_report": return "质量报告生成"
        case "structured_output": return "结构化多格式输出"
        default: return name
        }
    }
}
