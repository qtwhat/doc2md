import Foundation

// MARK: - Data Model

/// A single step in the conversion pipeline.
struct PipelineStep: Codable, Identifiable {
    var id: String { name }

    let name: String
    var enabled: Bool
    var parameters: [String: String]
}

/// A named, serialisable pipeline configuration.
struct PipelineConfig: Codable, Identifiable, Hashable {
    static func == (lhs: PipelineConfig, rhs: PipelineConfig) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }

    var id: String { name }

    let name: String
    let description: String
    var steps: [PipelineStep]
    var outputFormats: [String]  // e.g. ["markdown", "jsonl", "metadata", "raw", "claims", "report"]

    // MARK: - Built-in Presets

    /// Default preset -- every processing step enabled, standard Markdown output.
    static let `default` = PipelineConfig(
        name: "Default",
        description: "Full processing pipeline with Markdown output",
        steps: allSteps(overrides: [:]),
        outputFormats: ["markdown"]
    )

    /// Patent / 3GPP preset -- all steps plus claims extraction & report.
    static let patent3GPP = PipelineConfig(
        name: "Patent-3GPP",
        description: "Full pipeline with patent claims extraction and structured report",
        steps: allSteps(overrides: [
            "structured_output": ["extract_claims": "true", "extract_metadata": "true"]
        ]),
        outputFormats: ["markdown", "claims", "metadata", "report"]
    )

    /// Technical-spec preset -- no claims extraction, no metadata.
    static let technicalSpec = PipelineConfig(
        name: "Technical-Spec",
        description: "Clean technical document conversion without claims or metadata",
        steps: allSteps(overrides: [
            "structured_output": ["extract_claims": "false", "extract_metadata": "false"]
        ]),
        outputFormats: ["markdown"]
    )

    // MARK: - Query

    func isStepEnabled(_ name: String) -> Bool {
        steps.first(where: { $0.name == name })?.enabled ?? false
    }

    // MARK: - Serialisation

    /// Load a config from a JSON file.
    static func load(from url: URL) throws -> PipelineConfig {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(PipelineConfig.self, from: data)
    }

    /// Save this config to a JSON file.
    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Write the built-in presets to ~/Documents/Doc2Md/pipelines/ if they don't already exist.
    static func ensureDefaults() {
        let fm = FileManager.default
        let dir = pipelinesDirectory

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("[PipelineConfig] Could not create pipelines directory: \(error)")
            return
        }

        let presets: [PipelineConfig] = [.default, .patent3GPP, .technicalSpec]
        for preset in presets {
            let fileName = preset.name
                .lowercased()
                .replacingOccurrences(of: " ", with: "_")
                + ".json"
            let fileURL = dir.appendingPathComponent(fileName)
            if !fm.fileExists(atPath: fileURL.path) {
                do {
                    try preset.save(to: fileURL)
                } catch {
                    print("[PipelineConfig] Failed to write preset \(preset.name): \(error)")
                }
            }
        }
    }

    // MARK: - Helpers (private)

    static let pipelinesDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Doc2Md/pipelines")

    /// Canonical list of all pipeline steps with default parameters.
    /// `overrides` lets a preset replace parameter dictionaries for specific step names.
    private static func allSteps(overrides: [String: [String: String]]) -> [PipelineStep] {
        let base: [(String, [String: String])] = [
            ("vision_ocr",              ["render_scale": "2.0", "languages": "en,zh"]),
            ("column_reconstruction",   ["force_columns": "auto"]),
            ("punctuation_normalize",   ["mode": "auto"]),
            ("special_char_normalize",  [:]),
            ("hyphen_merge",            [:]),
            ("dictionary_correct",      ["dict_path": "default"]),
            ("noise_removal",           [:]),
            ("quality_report",          [:]),
            ("structured_output",       ["extract_claims": "false", "extract_metadata": "true"]),
        ]

        return base.map { (name, defaultParams) in
            let params = overrides[name] ?? defaultParams
            return PipelineStep(name: name, enabled: true, parameters: params)
        }
    }
}

// MARK: - Pipeline Manager

/// Singleton that discovers, loads, and exposes pipeline configurations.
class PipelineManager: ObservableObject {
    static let shared = PipelineManager()

    @Published var availableConfigs: [PipelineConfig] = []
    @Published var activeConfig: PipelineConfig = .default

    private let pipelinesDir: URL

    init() {
        pipelinesDir = PipelineConfig.pipelinesDirectory

        // Start with built-in presets immediately so the UI renders without
        // waiting on disk I/O. Any custom presets on disk are merged in on
        // a background queue.
        availableConfigs = [.default, .patent3GPP, .technicalSpec]
        activeConfig = .default

        DispatchQueue.global(qos: .utility).async { [weak self] in
            PipelineConfig.ensureDefaults()
            self?.loadConfigs()
        }
    }

    /// (Re)load all configs from the pipelines directory. May be called from
    /// a background queue; all @Published writes are dispatched back to main.
    func loadConfigs() {
        let fm = FileManager.default
        var configs: [PipelineConfig] = []

        if let files = try? fm.contentsOfDirectory(
            at: pipelinesDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) {
            for fileURL in files where fileURL.pathExtension == "json" {
                if let config = try? PipelineConfig.load(from: fileURL) {
                    configs.append(config)
                }
            }
        }

        // Always guarantee at least the built-in default is present
        if configs.isEmpty {
            configs = [.default, .patent3GPP, .technicalSpec]
        }

        let sorted = configs.sorted { $0.name < $1.name }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.availableConfigs = sorted

            // Keep activeConfig in sync -- if the current active name still exists, keep it
            if let match = sorted.first(where: { $0.name == self.activeConfig.name }) {
                self.activeConfig = match
            } else if let first = sorted.first {
                self.activeConfig = first
            }
        }
    }

    /// Persist the active config back to disk.
    func saveActiveConfig() {
        let fileName = activeConfig.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            + ".json"
        let fileURL = pipelinesDir.appendingPathComponent(fileName)
        try? activeConfig.save(to: fileURL)
        loadConfigs()
    }

    /// Add or replace a custom config and reload.
    func addConfig(_ config: PipelineConfig) {
        let fileName = config.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            + ".json"
        let fileURL = pipelinesDir.appendingPathComponent(fileName)
        try? config.save(to: fileURL)
        loadConfigs()
    }
}
