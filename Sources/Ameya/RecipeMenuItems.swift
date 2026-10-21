import AmeyaCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Menu bar → Recipes: run one on files you pick, edit, or import.
struct RecipeMenuItems: View {
    @EnvironmentObject private var store: JobStore
    @EnvironmentObject private var recipes: RecipeLibrary

    var body: some View {
        Menu("Recipes") {
            let tools = store.catalog.recipeTools()
            if tools.isEmpty { Text("No recipes yet") }
            ForEach(tools, id: \.id) { tool in
                Button("\(tool.title)…") { run(tool) }
            }
            Divider()
            Button("Edit Recipes…") { RecipeEditorWindow.show() }
            Button("Import Recipe…") { RecipeEditorWindow.importWithPanel() }
        }
        // Re-render when recipes change.
        .id(recipes.recipes.map(\.id))
    }

    /// Asks for files the recipe works on, then starts it, saving where Settings says.
    private func run(_ tool: Tool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files for “\(tool.title)”."
        panel.prompt = "Run Recipe"
        let accepted = RecipeShelf.entries.first { $0.recipe.toolID == tool.id }.map { Array($0.outputs.keys) } ?? []
        let types = accepted.compactMap { UTType($0.typeIdentifier) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let jobs = store.runNow(tool, on: OpenedFiles.accepted(panel.urls))
        if jobs.isEmpty {
            RecipeEditorWindow.alert("“\(tool.title)” doesn't work on these files", "Choose files of a kind the recipe accepts.")
        } else {
            AppDelegate.shared?.showMainWindow()
        }
    }
}

/// Menu bar → pause or resume every watched folder.
struct WatchMenuItems: View {
    @EnvironmentObject private var watch: WatchFolders

    var body: some View {
        if watch.enabledCount > 0 {
            Button(watch.isPaused ? "Resume Watch Folders" : "Pause Watch Folders") { watch.setPaused(!watch.isPaused) }
            if watch.activeCount > 0 {
                Text("Watch folders: converting \(watch.activeCount) file\(watch.activeCount == 1 ? "" : "s")")
            }
        }
    }
}

/// The menu bar icon, with a small count while watched folders are converting.
struct MenuBarLabel: View {
    @ObservedObject var watch: WatchFolders

    var body: some View {
        if watch.activeCount > 0 {
            // The icon, with the count beside it.
            HStack(spacing: 2) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("\(watch.activeCount)")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Ameya, converting \(watch.activeCount) files")
        } else {
            Image(systemName: watch.isPaused && watch.enabledCount > 0 ? "pause.circle" : "arrow.triangle.2.circlepath")
                .accessibilityLabel(watch.isPaused ? "Ameya, watch folders paused" : "Ameya")
        }
    }
}
