import Foundation

enum EpubOutputMode: String, CaseIterable, Identifiable {
    case singleFile = "single"
    case perChapter = "chapters"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .singleFile: return "单文件"
        case .perChapter: return "每章分离"
        }
    }

    var systemImage: String {
        switch self {
        case .singleFile: return "doc.text"
        case .perChapter: return "doc.on.doc"
        }
    }
}

class EpubSettings: ObservableObject {
    static let shared = EpubSettings()

    @Published var outputMode: EpubOutputMode {
        didSet { UserDefaults.standard.set(outputMode.rawValue, forKey: "epubOutputMode") }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: "epubOutputMode") ?? EpubOutputMode.singleFile.rawValue
        self.outputMode = EpubOutputMode(rawValue: raw) ?? .singleFile
    }
}
