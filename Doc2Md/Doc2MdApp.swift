import SwiftUI

// MARK: - App
//
// Performance-first architecture:
//   * Main window is a pure drop-zone + conversion list (see ContentView).
//   * All configuration lives in the standard macOS Settings window
//     (Command-,). That window is only instantiated when the user opens it,
//     so none of the settings UI costs anything at launch.

@main
struct Doc2MdApp: App {
    init() {
        // Dual-mode: if launched from a shell with file arguments, run as
        // CLI and exit before SwiftUI / NSApplicationMain takes over. The
        // dock icon never appears because we set activationPolicy(.prohibited)
        // before any drawing happens.
        if let exitCode = CLIDispatcher.maybeRun() {
            exit(exitCode)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 720, height: 520)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
    }
}
