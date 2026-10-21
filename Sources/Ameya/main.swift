import AppKit
import SwiftUI

// `Ameya --self-test` converts generated files through the real sandboxed worker and exits.
// CI runs it against the built app bundle.
if CommandLine.arguments.contains("--self-test") {
    exit(await SelfTest.run() ? 0 : 1)
}

AmeyaApp.main()

struct AmeyaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Ameya", id: "main") {
            MainView()
                .environmentObject(delegate.store)
                .background(WindowOpenerCapture())
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Ameya", systemImage: "arrow.triangle.2.circlepath") {
            MenuBarContent()
                .environmentObject(delegate.store)
        }

        Settings {
            SettingsView()
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
        .onAppear { AppDelegate.shared?.openMainWindow = { openWindow(id: "main") } }
        Button("Convert Clipboard…") { ClipboardActions.convertClipboard() }
            .keyboardShortcut("v")
        Menu("Copy Clipboard Picture As") {
            Button("JPEG") { ClipboardActions.copy(as: .jpeg) }
            Button("PNG") { ClipboardActions.copy(as: .png) }
            Button("PDF") { ClipboardActions.copy(as: .pdf) }
        }
        Divider()
        Button("Show Converted Files") {
            try? FileManager.default.createDirectory(at: store.outputDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(store.outputDirectory)
        }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Ameya") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Lets AppKit code reopen the main window after the user closed it.
private struct WindowOpenerCapture: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onAppear { AppDelegate.shared?.openMainWindow = { openWindow(id: "main") } }
    }
}
