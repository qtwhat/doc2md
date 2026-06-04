import SwiftUI
import UniformTypeIdentifiers

// MARK: - View Model

class ConversionViewModel: ObservableObject {
    @Published var items: [ConversionItem] = []
    private let engine = ConversionEngine()

    func processFiles(urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ConversionEngine.supportedExtensions.contains(ext) else { continue }

            let item = ConversionItem(sourceURL: url)
            DispatchQueue.main.async {
                self.items.insert(item, at: 0)
            }

            Task.detached { [weak self] in
                guard let self = self else { return }
                await MainActor.run { item.status = .converting }

                do {
                    let outputURLs = try self.engine.convert(url: url)
                    await MainActor.run {
                        item.outputURL = outputURLs.first
                        item.status = .success
                    }
                } catch {
                    await MainActor.run {
                        item.errorMessage = error.localizedDescription
                        item.status = .failed
                    }
                }
            }
        }
    }
}

// MARK: - ContentView
//
// Refactor target: performance first.
//   * No NavigationSplitView / sidebar — AppKit NSVisualEffectView + NSSplitView
//     first-time layout was the source of the expand-animation stutter.
//   * No toolbar dropdowns — all configuration is moved to the macOS menu bar
//     via `.commands` in Doc2MdApp (see CommandMenu("配置")). Menu bar items
//     only materialise when the user clicks the menu, so they are effectively
//     free at launch.
//   * View body is a flat VStack with two children. No @ObservedObject on any
//     global singleton lives here, so settings changes never invalidate this
//     view. Conversion progress is the only reactive surface.

struct ContentView: View {
    @StateObject private var viewModel = ConversionViewModel()
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            dropZone
            conversionList
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 440)
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
                .foregroundColor(isTargeted ? .accentColor : .secondary.opacity(0.5))
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )

            VStack(spacing: 12) {
                Image(systemName: "doc.badge.arrow.up")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("拖入文档")
                    .font(.title3)
                    .foregroundColor(.secondary)
                Text(".docx .doc .pdf .pptx .xlsx .epub .mobi .rtf .html .odt .txt .md .eml .msg .csv .json .xml .ipynb .png .jpg .heic .tiff .zip")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.8))
                Text("支持 \(ConversionEngine.supportedExtensions.count) 种格式 · 转换为 Markdown")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .multilineTextAlignment(.center)
        }
        .frame(height: 180)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    // MARK: - Conversion List

    private var conversionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.items.isEmpty {
                Text("转换记录")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.items) { item in
                        ConversionRow(item: item)
                    }
                }
            }
        }
    }

    // MARK: - Drop Handling

    private func handleDrop(providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let u = item as? URL {
                    url = u
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let str = item as? String {
                    url = URL(fileURLWithPath: str)
                } else {
                    url = nil
                }
                if let url = url {
                    urls.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            viewModel.processFiles(urls: urls)
        }
    }
}

// MARK: - Conversion Row

struct ConversionRow: View {
    @ObservedObject var item: ConversionItem

    var body: some View {
        HStack(spacing: 10) {
            fileIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error = item.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
                if let output = item.outputURL {
                    Text(output.lastPathComponent)
                        .font(.caption2)
                        .foregroundColor(.green)
                        .lineLimit(1)
                }
            }
            Spacer()
            statusIcon
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private var fileIcon: some View {
        Group {
            switch item.sourceURL.pathExtension.lowercased() {
            case "zip":
                Image(systemName: "doc.zipper")
            case "pdf":
                Image(systemName: "doc.text")
            case "pptx", "ppt":
                Image(systemName: "rectangle.on.rectangle")
            case "xlsx":
                Image(systemName: "tablecells")
            case "epub":
                Image(systemName: "book")
            case "mobi", "azw", "azw3":
                Image(systemName: "book.closed")
            case "eml", "msg":
                Image(systemName: "envelope")
            case "csv", "tsv":
                Image(systemName: "tablecells")
            case "json", "xml":
                Image(systemName: "curlybraces")
            case "ipynb":
                Image(systemName: "function")
            case "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp":
                Image(systemName: "photo")
            case "rtf":
                Image(systemName: "doc.richtext")
            case "html", "htm":
                Image(systemName: "globe")
            case "txt":
                Image(systemName: "doc.plaintext")
            case "md", "markdown":
                Image(systemName: "text.alignleft")
            case "odt":
                Image(systemName: "doc")
            default:
                Image(systemName: "doc.richtext")
            }
        }
        .font(.title3)
        .foregroundColor(.accentColor)
        .frame(width: 28)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: "clock")
                .foregroundColor(.secondary)
        case .converting:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }
}
