import AmeyaCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Recipes window, plus importing and exporting `.ameyarecipe` files.
@MainActor
enum RecipeEditorWindow {
    private static var window: NSWindow?

    static func show(selecting id: UUID? = nil) {
        guard let delegate = AppDelegate.shared else { return }
        if window == nil {
            let host = NSHostingController(rootView: RecipeEditorView(library: delegate.recipes, store: delegate.store,
                                                                      initialSelection: id))
            let window = NSWindow(contentViewController: host)
            window.title = "Recipes"
            window.identifier = NSUserInterfaceItemIdentifier("recipes")
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 720, height: 520))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static var recipeType: UTType {
        UTType(RecipeFile.typeIdentifier) ?? UTType(filenameExtension: RecipeFile.fileExtension) ?? .json
    }

    /// Imports each file, reporting refusals in plain words, then shows the window.
    static func importFiles(_ urls: [URL]) {
        guard let library = AppDelegate.shared?.recipes else { return }
        var last: UUID?
        var problems: [String] = []
        for url in urls {
            do {
                last = try library.importRecipe(from: url).id
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                problems.append("\(url.lastPathComponent): \(reason)")
            }
        }
        window = nil // Rebuild so the new recipe is selected.
        show(selecting: last)
        if !problems.isEmpty { alert("Some recipes weren't imported", problems.joined(separator: "\n")) }
    }

    static func importWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [recipeType]
        panel.allowsMultipleSelection = true
        panel.message = "Choose Ameya recipe files to add."
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    static func export(_ recipe: Recipe) {
        guard let library = AppDelegate.shared?.recipes else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [recipeType]
        panel.nameFieldStringValue = "\(recipe.name.replacingOccurrences(of: "/", with: "-")).\(RecipeFile.fileExtension)"
        panel.message = "Save this recipe as a file you can share."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try library.export(recipe, to: url) } catch { alert("The recipe wasn't saved", error.localizedDescription) }
    }

    static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

struct RecipeEditorView: View {
    @ObservedObject var library: RecipeLibrary
    let store: JobStore
    @State private var selection: UUID?
    @State private var draft: Recipe?
    @State private var confirmDelete = false

    init(library: RecipeLibrary, store: JobStore, initialSelection: UUID?) {
        self.library = library
        self.store = store
        _selection = State(initialValue: initialSelection ?? library.recipes.first?.id)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(library.recipes) { recipe in
                        Label(recipe.name, systemImage: recipe.symbol)
                            .foregroundStyle(library.analysis(of: recipe).isValid ? .primary : .secondary)
                            .tag(recipe.id)
                    }
                }
                .accessibilityLabel("Recipes")
                HStack(spacing: 4) {
                    Button { newRecipe() } label: { Image(systemName: "plus") }
                        .help("New recipe").accessibilityLabel("New recipe")
                    Button { confirmDelete = true } label: { Image(systemName: "minus") }
                        .help("Delete recipe").accessibilityLabel("Delete recipe")
                        .disabled(selection == nil)
                    Spacer()
                    Menu {
                        Button("Import Recipe…") { RecipeEditorWindow.importWithPanel() }
                        Button("Export Recipe…") { if let draft { RecipeEditorWindow.export(draft) } }
                            .disabled(draft == nil)
                    } label: { Image(systemName: "square.and.arrow.up.on.square") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Import or export")
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)

            Group {
                if let binding = Binding($draft) {
                    RecipeDetail(recipe: binding, library: library, store: store, saved: saved)
                } else {
                    Text("Choose a recipe, or press + to make one.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420)
        }
        .tint(Theme.accent)
        .onAppear { load() }
        .onChange(of: selection) { _, _ in load() }
        .confirmationDialog("Delete this recipe?", isPresented: $confirmDelete) {
            Button("Delete Recipe", role: .destructive) {
                if let selection { library.delete(selection) }
                selection = library.recipes.first?.id
            }
        } message: {
            Text("Files you already made with it are not affected.")
        }
    }

    private var saved: Recipe? { selection.flatMap(library.recipe(id:)) }

    private func load() { draft = saved }

    /// Starts from "Convert to JPEG", which always fits, so it can be saved straight away.
    private func newRecipe() {
        let recipe = library.makeNew()
        try? library.save(recipe)
        selection = recipe.id
        load()
    }
}

/// Name, icon, steps and what the recipe takes and makes.
private struct RecipeDetail: View {
    @Binding var recipe: Recipe
    @ObservedObject var library: RecipeLibrary
    let store: JobStore
    let saved: Recipe?
    @State private var selectedStep: Int?
    @State private var error: String?

    var body: some View {
        let analysis = library.analysis(of: recipe)
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: $recipe.name)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .accessibilityLabel("Recipe name")
            SymbolPicker(symbol: $recipe.symbol)

            Text("Steps").font(.headline)
            List(selection: $selectedStep) {
                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(library.planner.title(of: step))")
                        .tag(index)
                        .accessibilityLabel("Step \(index + 1) of \(recipe.steps.count): \(library.planner.title(of: step))")
                }
            }
            .frame(minHeight: 120)
            HStack {
                AddStepMenu(store: store) { step in
                    guard recipe.steps.count < Recipe.maxSteps else { return }
                    let at = selectedStep.map { $0 + 1 } ?? recipe.steps.count
                    recipe.steps.insert(step, at: at)
                    selectedStep = at
                }
                Button("Move Up") { move(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled((selectedStep ?? 0) == 0)
                Button("Move Down") { move(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(selectedStep.map { $0 >= recipe.steps.count - 1 } ?? true)
                Button("Remove Step") {
                    if let index = selectedStep, recipe.steps.indices.contains(index) {
                        recipe.steps.remove(at: index)
                        selectedStep = recipe.steps.isEmpty ? nil : min(index, recipe.steps.count - 1)
                    }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selectedStep == nil)
            }

            Preview(analysis: analysis)

            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("Revert") { if let saved { recipe = saved } }
                    .disabled(saved == nil || saved == recipe)
                Button("Save Recipe") {
                    recipe.name = recipe.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    do { try library.save(recipe); error = nil } catch {
                        self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!analysis.isValid || recipe.name.trimmingCharacters(in: .whitespaces).isEmpty
                          || recipe.name.count > Recipe.maxNameLength || saved == recipe)
            }
        }
        .padding()
    }

    private func move(by offset: Int) {
        guard let index = selectedStep, recipe.steps.indices.contains(index + offset) else { return }
        recipe.steps.swapAt(index, index + offset)
        selectedStep = index + offset
    }
}

/// "Takes PNG, JPEG… · Makes JPEG", or why the steps don't fit.
private struct Preview: View {
    let analysis: RecipeAnalysis

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                if let problem = analysis.problem {
                    Label(problem.errorDescription ?? "These steps don't fit together.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Label("Works on: \(names(analysis.accepts))", systemImage: "tray.and.arrow.down")
                    Label("Makes: \(names(analysis.produces))", systemImage: "tray.and.arrow.up")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private func names(_ formats: [FileFormat]) -> String {
        let shown = formats.prefix(8).map(\.displayName).joined(separator: ", ")
        return formats.count > 8 ? "\(shown) and \(formats.count - 8) more" : shown
    }
}

/// Adds a "convert to" or tool step.
private struct AddStepMenu: View {
    let store: JobStore
    let add: (RecipeStep) -> Void

    var body: some View {
        Menu("Add Step") {
            Menu("Convert to") {
                ForEach(targets) { format in Button(format.displayName) { add(.convert(format)) } }
            }
            Menu("Tool") {
                ForEach(store.catalog.recipeStepTools, id: \.id) { tool in
                    Button { add(.tool(tool.id)) } label: { Label(tool.title, systemImage: tool.systemImage) }
                }
            }
        }
        .fixedSize()
    }

    private var targets: [FileFormat] { store.recipePlanner.reachableTargets }
}

/// A row of friendly icons; arrow keys and Space work through the buttons.
private struct SymbolPicker: View {
    @Binding var symbol: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 11), alignment: .leading, spacing: 4) {
            ForEach(Recipe.symbols, id: \.self) { name in
                Button { symbol = name } label: {
                    Image(systemName: name)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(symbol == name ? Theme.accent.opacity(0.25) : .clear))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Icon: \(name.replacingOccurrences(of: ".", with: " "))")
                .accessibilityAddTraits(symbol == name ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recipe icon")
    }
}
