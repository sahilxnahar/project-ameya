import AmeyaCore
import Foundation
import os

/// The recipes the catalog offers as tools, readable from any thread: `ToolCatalog` is a plain
/// value used on and off the main actor. `RecipeLibrary` publishes here whenever recipes change.
enum RecipeShelf {
    struct Entry: Sendable {
        let recipe: Recipe
        /// Each accepted source format and the format it ends up in.
        let outputs: [FileFormat: FileFormat]
        let stepTitles: [String]
    }

    private static let lock = OSAllocatedUnfairLock<[Entry]>(initialState: [])
    static var entries: [Entry] { lock.withLock { $0 } }
    static func publish(_ entries: [Entry]) { lock.withLock { $0 = entries } }
}

extension ToolCatalog {
    /// One-click tools a recipe step may use: one file in, one file out, no settings sheet.
    var recipeStepTools: [Tool] {
        builtInTools.filter { $0.mode == .eachFile && $0.panel == nil && !$0.producesFolder }
    }

    func recipePlanner(matrix: ConversionMatrix) -> RecipePlanner {
        RecipePlanner(matrix: matrix, tools: recipeStepTools.map { tool in
            RecipeToolInfo(id: tool.id, title: tool.title) { format in
                tool.isAvailable([format]) ? tool.makeRequest(format) : nil
            }
        })
    }

    /// The user's recipes, as tools (the main window, the drag wheel's tools ring, the menu bar).
    func recipeTools() -> [Tool] {
        RecipeShelf.entries.map { entry in
            let steps = entry.stepTitles.joined(separator: ", then ")
            var tool = Tool(
                id: entry.recipe.toolID, title: entry.recipe.name, systemImage: entry.recipe.symbol,
                help: "Recipe with \(entry.stepTitles.count) step\(entry.stepTitles.count == 1 ? "" : "s"): \(steps).",
                outputSuffix: "(edited)",
                isAvailable: { formats in !formats.isEmpty && formats.allSatisfy { entry.outputs[$0] != nil } },
                makeRequest: { format in ConversionRequest(source: format, target: entry.outputs[format] ?? format) })
            tool.recipe = entry.recipe
            return tool
        }
    }
}

/// Runs a recipe's planned steps through sandboxed workers, one job per step.
enum RecipeJobs {
    static func execute(worker: URL) -> RecipeRunner.Execute {
        { step, input, destination, progress in
            var timeout = step.request.source?.family.timeout ?? .seconds(300)
            if case .ocr = step.request.options.pdf { timeout = .seconds(3600) }
            return try await WorkerRunner(executable: worker, timeout: timeout)
                .run(input: input, destination: destination, request: step.request, progress: progress)
        }
    }

    static func run(_ steps: [PlannedRecipeStep], input: URL, destination: URL, worker: URL,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> ConversionResult {
        try await RecipeRunner.run(steps, input: input, destination: destination, progress: progress,
                                   execute: execute(worker: worker))
    }
}

/// The user's recipes: kept in UserDefaults, checked against this Mac, shown as tools.
@MainActor
final class RecipeLibrary: ObservableObject {
    static let storageKey = "recipes"
    static let startersKey = "recipeStartersAdded"

    @Published private(set) var recipes: [Recipe] = []
    let planner: RecipePlanner
    private let defaults: UserDefaults

    init(store: JobStore, defaults: UserDefaults = .standard) {
        planner = store.recipePlanner
        self.defaults = defaults
        var loaded = (defaults.data(forKey: Self.storageKey))
            .flatMap { try? JSONDecoder().decode([Recipe].self, from: $0) } ?? []
        if !defaults.bool(forKey: Self.startersKey) {
            loaded += Recipe.starters.filter { starter in !loaded.contains { $0.id == starter.id } }
            defaults.set(true, forKey: Self.startersKey)
        }
        recipes = loaded
        save()
    }

    func analysis(of recipe: Recipe) -> RecipeAnalysis { planner.analyse(recipe) }

    func recipe(id: UUID) -> Recipe? { recipes.first { $0.id == id } }

    /// Adds or replaces (same id) a recipe. Recipes whose steps don't fit are refused.
    func save(_ recipe: Recipe) throws {
        if let problem = analysis(of: recipe).problem { throw problem }
        if let index = recipes.firstIndex(where: { $0.id == recipe.id }) {
            recipes[index] = recipe
        } else {
            recipes.append(recipe)
        }
        save()
    }

    func delete(_ id: UUID) {
        recipes.removeAll { $0.id == id }
        save()
    }

    /// A new, empty-ish recipe the editor starts from.
    func makeNew() -> Recipe {
        Recipe(name: "New recipe", symbol: Recipe.symbols[0], steps: [.convert(.jpeg)])
    }

    // MARK: Files

    /// Reads an `.ameyarecipe` file strictly and adds it. Returns the new recipe.
    @discardableResult
    func importRecipe(from url: URL) throws -> Recipe {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= RecipeFile.maxBytes else { throw RecipeImportError.tooLarge }
        var recipe = try RecipeFile.decode(try Data(contentsOf: url))
        if let problem = analysis(of: recipe).problem { throw problem }
        // Two recipes with the same name would look identical in menus.
        let names = Set(recipes.map(\.name))
        if names.contains(recipe.name) {
            var counter = 2
            while names.contains("\(recipe.name) \(counter)") { counter += 1 }
            recipe.name = "\(recipe.name) \(counter)"
        }
        try save(recipe)
        return recipe
    }

    func export(_ recipe: Recipe, to url: URL) throws {
        try RecipeFile.encode(recipe).write(to: url, options: .atomic)
    }

    // MARK: Storage

    private func save() {
        if let data = try? JSONEncoder().encode(recipes) { defaults.set(data, forKey: Self.storageKey) }
        publish()
    }

    /// Tells the catalog (and so the window, the wheel and the menu bar) about usable recipes.
    private func publish() {
        RecipeShelf.publish(recipes.compactMap { recipe in
            let analysis = analysis(of: recipe)
            guard analysis.isValid else { return nil }
            var outputs: [FileFormat: FileFormat] = [:]
            for source in analysis.accepts {
                outputs[source] = planner.output(of: recipe, for: source)
            }
            return RecipeShelf.Entry(recipe: recipe, outputs: outputs, stepTitles: recipe.steps.map(planner.title(of:)))
        })
        objectWillChange.send()
    }
}
