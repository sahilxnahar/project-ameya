import AppKit
import SwiftUI

// `Ameya --self-test` converts generated files through the real sandboxed worker and exits.
// CI runs it against the built app bundle.
if CommandLine.arguments.contains("--self-test") {
    exit(await SelfTest.run() ? 0 : 1)
}
// `Ameya --snapshots` renders the main views to PNGs (for docs/screenshots) and exits.
if CommandLine.arguments.contains("--snapshots") {
    exit(await Snapshots.run() ? 0 : 1)
}

// `Ameya --bench` measures setup, drop → job start, worker overhead and memory, then exits.
if CommandLine.arguments.contains("--bench") {
    exit(await Benchmark.run() ? 0 : 1)
}

AmeyaApp.main()

/// A menu bar app (`LSUIElement`): the status item, its panel and the windows are AppKit
/// (MenuBar/), made by `AppDelegate`. SwiftUI provides the menu bar commands and the views.
struct AmeyaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        // Ameya's own status item, panel and windows are AppKit (MenuBar/). SwiftUI needs a scene,
        // so this one is never inserted: it only carries the menu commands. (A SwiftUI Settings
        // scene would pop up its own window when the app activates, and can't be opened from
        // AppKit on macOS 14; Settings open in `AppDelegate.showSettings()` instead.)
        MenuBarExtra("Ameya", isInserted: .constant(false)) {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { AppDelegate.shared?.showSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("New Ameya Window") { AppDelegate.shared?.showMainWindow() }
                    .keyboardShortcut("n")
                Button("Open Menu Bar Panel") { AppDelegate.shared?.showPanel() }
            }
        }
    }
}
