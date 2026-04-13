import Foundation

enum ConversionStatus {
    case pending
    case converting
    case success
    case failed
}

class ConversionItem: Identifiable, ObservableObject {
    let id = UUID()
    let sourceURL: URL
    let fileName: String
    @Published var status: ConversionStatus
    @Published var outputURL: URL?
    @Published var errorMessage: String?

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
        self.fileName = sourceURL.lastPathComponent
        self.status = .pending
    }
}
