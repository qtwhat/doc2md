import Foundation

enum ZipExtractorError: LocalizedError {
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .extractionFailed(let msg):
            return "ZIP 解压失败: \(msg)"
        }
    }
}

struct ZipExtractor {
    static func extract(url: URL) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", url.path, "-d", tempDir.path]

        // Discard stdout to avoid pipe buffer deadlock on large files.
        // Keep stderr in a pipe so we can report errors.
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe

        // Read stderr asynchronously to prevent deadlock
        var errData = Data()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            errData.append(handle.availableData)
        }

        try process.run()
        process.waitUntilExit()

        errPipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw ZipExtractorError.extractionFailed(errMsg)
        }

        return tempDir
    }

    static func cleanup(tempDir: URL) {
        try? FileManager.default.removeItem(at: tempDir)
    }
}
