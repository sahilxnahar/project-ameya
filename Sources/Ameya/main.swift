import AppKit
import SwiftUI

// `Ameya --self-test` converts generated files through the real sandboxed worker and exits.
// CI runs it against the built app bundle.
if CommandLine.arguments.contains("--self-test") {
    exit(await SelfTest.run() ? 0 : 1)
}

AmeyaApp.main()

struct AmeyaApp: App {
    @StateObject private var store = JobStore()

    var body: some Scene {
        Window("Ameya", id: "main") {
            MainView()
                .environmentObject(store)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Ameya", systemImage: "arrow.triangle.2.circlepath") {
            MenuBarContent()
                .environmentObject(store)
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var store: JobStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Ameya") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("o")
        Button("Show Converted Files") {
            try? FileManager.default.createDirectory(at: store.outputDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(store.outputDirectory)
        }
        Divider()
        Button("Quit Ameya") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
