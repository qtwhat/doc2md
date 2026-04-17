import Foundation
import Combine

/// Monitors a directory for new document files and auto-converts them to Markdown.
class FolderWatcher: ObservableObject {

    static let shared = FolderWatcher()

    // MARK: - Published State

    @Published var isWatching = false
    @Published var watchedFolder: URL?
    @Published var outputFolder: URL?
    @Published var processedCount = 0
    @Published var lastError: String?

    // MARK: - Private

    private var monitor: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var processedFiles: Set<String> = []  // Track already-processed file names
    private let engine = ConversionEngine()
    private var supportedExtensions: Set<String> { ConversionEngine.supportedExtensions }

    // MARK: - Defaults

    static let defaultWatchFolder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Doc2Md/ToConvert")

    static let defaultOutputFolder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Doc2Md/Converted")

    // UserDefaults keys
    private enum DefaultsKey {
        static let watchFolder = "FolderWatcher.watchFolder"
        static let outputFolder = "FolderWatcher.outputFolder"
    }

    // MARK: - Init

    init() {
        // Restore persisted folder paths
        if let path = UserDefaults.standard.string(forKey: DefaultsKey.watchFolder) {
            watchedFolder = URL(fileURLWithPath: path)
        }
        if let path = UserDefaults.standard.string(forKey: DefaultsKey.outputFolder) {
            outputFolder = URL(fileURLWithPath: path)
        }
    }

    deinit {
        stopWatching()
    }

    // MARK: - Public API

    /// Begin watching the given folder (or the previously saved / default folder).
    func startWatching(folder: URL? = nil, output: URL? = nil) {
        stopWatching()  // tear down any existing monitor

        let watch = folder ?? watchedFolder ?? Self.defaultWatchFolder
        let out = output ?? outputFolder ?? Self.defaultOutputFolder

        // Ensure directories exist
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: watch, withIntermediateDirectories: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
        } catch {
            lastError = "Could not create folders: \(error.localizedDescription)"
            return
        }

        // Persist choices
        watchedFolder = watch
        outputFolder = out
        UserDefaults.standard.set(watch.path, forKey: DefaultsKey.watchFolder)
        UserDefaults.standard.set(out.path, forKey: DefaultsKey.outputFolder)

        // Open a file descriptor on the directory
        fileDescriptor = open(watch.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            lastError = "Could not open folder for monitoring: \(watch.path)"
            return
        }

        // Create a GCD file-system monitor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,  // fires when directory contents change
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.scanForNewFiles()
        }

        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        monitor = source
        source.resume()

        DispatchQueue.main.async {
            self.isWatching = true
            self.lastError = nil
        }

        // Do an initial scan so files already present get picked up
        scanForNewFiles()
    }

    /// Stop monitoring.
    func stopWatching() {
        monitor?.cancel()
        monitor = nil

        DispatchQueue.main.async {
            self.isWatching = false
        }
    }

    // MARK: - Private Helpers

    /// Enumerate the watched folder and process any unhandled files.
    private func scanForNewFiles() {
        guard let watchDir = watchedFolder else { return }
        let fm = FileManager.default

        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: watchDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            DispatchQueue.main.async {
                self.lastError = "Scan error: \(error.localizedDescription)"
            }
            return
        }

        for fileURL in contents {
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }

            let fileName = fileURL.lastPathComponent
            guard !processedFiles.contains(fileName) else { continue }

            // Mark as processed immediately to avoid double-processing
            processedFiles.insert(fileName)
            processFile(fileURL)
        }
    }

    /// Convert a single file and move the original to the output folder.
    private func processFile(_ url: URL) {
        guard let outDir = outputFolder else { return }

        do {
            // Run conversion (produces .md file(s) next to the original)
            let resultURLs = try engine.convert(url: url)

            let fm = FileManager.default

            // Move each generated markdown into the output folder
            for mdURL in resultURLs {
                let dest = outDir.appendingPathComponent(mdURL.lastPathComponent)
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.moveItem(at: mdURL, to: dest)
            }

            // Move (or remove) the original source file into the output folder
            let originalDest = outDir.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: originalDest.path) {
                try fm.removeItem(at: originalDest)
            }
            try fm.moveItem(at: url, to: originalDest)

            DispatchQueue.main.async {
                self.processedCount += 1
                self.lastError = nil
            }
        } catch {
            // Log per-file error but keep watching for other files
            DispatchQueue.main.async {
                self.lastError = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }
}
