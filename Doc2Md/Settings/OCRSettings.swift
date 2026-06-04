import Foundation

enum OCRLanguageProfile: String, CaseIterable, Identifiable {
    case english = "en"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .chineseSimplified: return "简体中文"
        case .chineseTraditional: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }
}

enum OCRRenderScale: Double, CaseIterable, Identifiable {
    case low = 2.0
    case medium = 3.0
    case high = 4.0

    var id: Double { rawValue }

    var displayName: String {
        switch self {
        case .low: return "2x (快速)"
        case .medium: return "3x (推荐)"
        case .high: return "4x (高精度)"
        }
    }
}

enum PunctuationMode: String, CaseIterable, Identifiable {
    case halfWidth = "half"
    case fullWidth = "full"
    case auto = "auto"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .halfWidth: return "半角 (English)"
        case .fullWidth: return "全角 (中日韩)"
        case .auto: return "自动 (按主语言)"
        }
    }
}

class OCRSettings: ObservableObject {
    static let shared = OCRSettings()

    @Published var renderScale: OCRRenderScale {
        didSet { UserDefaults.standard.set(renderScale.rawValue, forKey: "ocrRenderScale") }
    }

    @Published var primaryLanguage: OCRLanguageProfile {
        didSet { UserDefaults.standard.set(primaryLanguage.rawValue, forKey: "ocrPrimaryLanguage") }
    }

    @Published var secondaryLanguage: OCRLanguageProfile? {
        didSet { UserDefaults.standard.set(secondaryLanguage?.rawValue ?? "", forKey: "ocrSecondaryLanguage") }
    }

    @Published var punctuationMode: PunctuationMode {
        didSet { UserDefaults.standard.set(punctuationMode.rawValue, forKey: "ocrPunctuationMode") }
    }

    @Published var enableOCRCorrection: Bool {
        didSet { UserDefaults.standard.set(enableOCRCorrection, forKey: "ocrEnableCorrection") }
    }

    /// When true, Vision auto-detects the script in the image (CJK / Latin /
    /// etc.) and ignores the manual primary/secondary language pickers below.
    /// This is the recommended default — it's what makes a Chinese-dominant
    /// document OCR correctly even if the user hasn't manually set Chinese
    /// as primary. When false, the manual language order applies.
    @Published var automaticallyDetectsLanguage: Bool {
        didSet { UserDefaults.standard.set(automaticallyDetectsLanguage, forKey: "ocrAutoDetect") }
    }

    init() {
        let scale = UserDefaults.standard.double(forKey: "ocrRenderScale")
        self.renderScale = OCRRenderScale(rawValue: scale) ?? .medium

        let lang = UserDefaults.standard.string(forKey: "ocrPrimaryLanguage") ?? "en"
        self.primaryLanguage = OCRLanguageProfile(rawValue: lang) ?? .english

        let secLang = UserDefaults.standard.string(forKey: "ocrSecondaryLanguage") ?? "zh-Hans"
        self.secondaryLanguage = secLang.isEmpty ? nil : OCRLanguageProfile(rawValue: secLang)

        let punct = UserDefaults.standard.string(forKey: "ocrPunctuationMode") ?? "auto"
        self.punctuationMode = PunctuationMode(rawValue: punct) ?? .auto

        if UserDefaults.standard.object(forKey: "ocrEnableCorrection") == nil {
            self.enableOCRCorrection = true
        } else {
            self.enableOCRCorrection = UserDefaults.standard.bool(forKey: "ocrEnableCorrection")
        }

        if UserDefaults.standard.object(forKey: "ocrAutoDetect") == nil {
            self.automaticallyDetectsLanguage = true
        } else {
            self.automaticallyDetectsLanguage = UserDefaults.standard.bool(forKey: "ocrAutoDetect")
        }
    }

    var recognitionLanguages: [String] {
        var langs = [primaryLanguage.rawValue]
        if let sec = secondaryLanguage, sec != primaryLanguage {
            langs.append(sec.rawValue)
        }
        return langs
    }

    var shouldNormalizeToHalfWidth: Bool {
        switch punctuationMode {
        case .halfWidth: return true
        case .fullWidth: return false
        case .auto: return primaryLanguage == .english
        }
    }
}
