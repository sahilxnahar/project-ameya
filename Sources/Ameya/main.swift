import AppKit
import SwiftUI

// Started as `ameya` (Contents/Helpers/ameya): the command-line tool (Automation/CommandLineTool.swift).
if CommandLineTool.isRequested() {
    exit(await CommandLineTool.main())
}
// `Ameya --self-test` converts generated files through the real sandboxed worker and exits.
// CI runs it against the built app bundle.
if CommandLine.arguments.contains("--self-test") {
    exit(await SelfTest.run() ? 0 : 1)
}
// `Ameya --snapshots` renders the main views to PNGs (for docs/screenshots) and exits.
if CommandLine.arguments.contains("--snapshots") {
    exit(await Snapshots.run() ? 0 : 1)
}

AmeyaApp.main()

struct AmeyaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Ameya", id: "main") {
            MainView()
                .environmentObject(delegate.store)
                .environmentObject(delegate.results)
                .background(WindowOpenerCapture())
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 560, height: 640)

        MenuBarExtra("Ameya", systemImage: "arrow.triangle.2.circlepath") {
            MenuBarContent()
                .environmentObject(delegate.store)
                .environmentObject(delegate.results)
        }

        Settings {
            SettingsView()
        }
    }
}

/// The menu bar menu. Every item is plain text, so VoiceOver reads it as written.
struct MenuBarContent: View {
    @EnvironmentObject private var store: JobStore
    @EnvironmentObject private var results: ResultsModel
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
        WheelMenuItems()
        Divider()
        Menu("Recent") {
            let recent = results.recent.items.prefix(8)
            if recent.isEmpty {
                Text("Nothing yet")
            } else {
                ForEach(Array(recent)) { file in
                    Button(file.name) { NSWorkspace.shared.open(file.url) }
                        .disabled(!results.exists(file))
                }
                Divider()
                Button("Clear Recent") { results.clearRecent() }
            }
        }
        Button("Show Converted Files") {
            try? FileManager.default.createDirectory(at: store.outputDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(store.outputDirectory)
        }
        Divider()
        Button("Welcome Tour…") { AppDelegate.shared?.showWelcomeTour() }
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
