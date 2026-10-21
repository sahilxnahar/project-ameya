import Foundation

/// What the planner needs to know about a one-click tool. The app builds these from its catalog;
/// tests build their own.
public struct RecipeToolInfo {
    public let id: String
    public let title: String
    /// The request for one file of this format, or `nil` when the tool doesn't apply to it.
    public let request: (FileFormat) -> ConversionRequest?

    public init(id: String, title: String, request: @escaping (FileFormat) -> ConversionRequest?) {
        self.id = id
        self.title = title
        self.request = request
    }
}

/// One worker job of a recipe run, for a known input format.
public struct PlannedRecipeStep: Sendable, Equatable {
    /// 1-based position in the recipe, as people count.
    public let number: Int
    /// "Convert to JPEG", "Remove location", …
    public let title: String
    public let request: ConversionRequest

    public init(number: Int, title: String, request: ConversionRequest) {
        self.number = number
        self.title = title
        self.request = request
    }
}

/// Why a recipe can't be used, found before anything runs.
public enum RecipeProblem: Error, Equatable, LocalizedError {
    case noSteps
    case tooManySteps
    case unknownTool(step: Int, id: String)
    /// Nothing that reaches this step can go through it. `after` lists what arrives there
    /// (empty for step 1, where every kind of file was tried).
    case stepDoesNotFit(step: Int, title: String, after: [FileFormat])

    public var errorDescription: String? {
        switch self {
        case .noSteps: "Add at least one step."
        case .tooManySteps: "A recipe can have at most \(Recipe.maxSteps) steps."
        case let .unknownTool(step, id): "Step \(step) uses a tool this Mac doesn't have (\(id))."
        case let .stepDoesNotFit(step, title, after) where step == 1 || after.isEmpty:
            "Step \(step) (\(title)) doesn't work on any kind of file."
        case let .stepDoesNotFit(step, title, after):
            "Step \(step) (\(title)) can't work on the \(RecipePlanner.list(after)) that step \(step - 1) makes."
        }
    }
}

/// What a recipe accepts and makes, worked out from the conversion matrix.
public struct RecipeAnalysis: Equatable, Sendable {
    /// Source formats the whole chain works for, in `FileFormat.allCases` order.
    public var accepts: [FileFormat]
    /// Formats the recipe can end with.
    public var produces: [FileFormat]
    public var problem: RecipeProblem?

    public var isValid: Bool { problem == nil && !accepts.isEmpty }
}

/// Turns a recipe into worker requests, and refuses chains whose steps don't fit together.
///
/// A "convert" step whose file already is in that format is skipped (a JPEG through "Convert to
/// JPEG" stays as it is). Tools that make several files are refused: a recipe makes one file.
public struct RecipePlanner {
    public let matrix: ConversionMatrix
    private let tools: [String: RecipeToolInfo]

    public init(matrix: ConversionMatrix, tools: [RecipeToolInfo]) {
        self.matrix = matrix
        self.tools = Dictionary(tools.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Formats a recipe could start from: every real format.
    public static let candidateSources = FileFormat.allCases.filter { !RecipeFile.unusableTargets.contains($0) }

    public func hasTool(_ id: String) -> Bool { tools[id] != nil }

    /// Plain words for one step, for the editor and for error messages.
    public func title(of step: RecipeStep) -> String {
        switch step {
        case let .convert(format): "Convert to \(format.displayName)"
        case let .tool(id): tools[id]?.title ?? id
        }
    }

    /// The worker jobs for a file of `source`, or `nil` when the recipe doesn't suit it.
    /// Empty when every step is a conversion to the format the file already has.
    public func plan(_ recipe: Recipe, for source: FileFormat) -> [PlannedRecipeStep]? {
        var cache: [FileFormat: Set<FileFormat>] = [:]
        return plan(recipe, for: source, cache: &cache)
    }

    /// The format a file of `source` ends up in, or `nil` when the recipe doesn't suit it.
    public func output(of recipe: Recipe, for source: FileFormat) -> FileFormat? {
        guard let steps = plan(recipe, for: source) else { return nil }
        return steps.last?.request.target ?? source
    }

    public func analyse(_ recipe: Recipe, candidates: [FileFormat] = RecipePlanner.candidateSources) -> RecipeAnalysis {
        guard !recipe.steps.isEmpty else { return RecipeAnalysis(accepts: [], produces: [], problem: .noSteps) }
        guard recipe.steps.count <= Recipe.maxSteps else {
            return RecipeAnalysis(accepts: [], produces: [], problem: .tooManySteps)
        }
        for (index, step) in recipe.steps.enumerated() {
            if case let .tool(id) = step, tools[id] == nil {
                return RecipeAnalysis(accepts: [], produces: [], problem: .unknownTool(step: index + 1, id: id))
            }
        }
        var cache: [FileFormat: Set<FileFormat>] = [:]
        // Each surviving source, and the format it has reached so far.
        var alive: [(source: FileFormat, current: FileFormat)] = candidates.map { ($0, $0) }
        for (index, step) in recipe.steps.enumerated() {
            let arriving = index == 0 ? [] : Self.unique(alive.map(\.current))
            alive = alive.compactMap { pair in
                next(after: pair.current, through: step, cache: &cache).map { (pair.source, $0.target) }
            }
            if alive.isEmpty {
                let problem = RecipeProblem.stepDoesNotFit(step: index + 1, title: title(of: step), after: arriving)
                return RecipeAnalysis(accepts: [], produces: [], problem: problem)
            }
        }
        return RecipeAnalysis(accepts: alive.map(\.source), produces: Self.unique(alive.map(\.current)), problem: nil)
    }

    // MARK: Internals

    private func plan(_ recipe: Recipe, for source: FileFormat,
                      cache: inout [FileFormat: Set<FileFormat>]) -> [PlannedRecipeStep]? {
        guard !recipe.steps.isEmpty, recipe.steps.count <= Recipe.maxSteps else { return nil }
        var current = source
        var planned: [PlannedRecipeStep] = []
        for (index, step) in recipe.steps.enumerated() {
            guard let move = next(after: current, through: step, cache: &cache) else { return nil }
            if let request = move.request {
                planned.append(PlannedRecipeStep(number: index + 1, title: title(of: step), request: request))
            }
            current = move.target
        }
        return planned
    }

    /// Where one step takes a file of `format`: the format it ends in, and the request to get
    /// there (`nil` for a conversion that isn't needed). `nil` when the step doesn't fit.
    private func next(after format: FileFormat, through step: RecipeStep,
                      cache: inout [FileFormat: Set<FileFormat>]) -> (target: FileFormat, request: ConversionRequest?)? {
        switch step {
        case let .convert(target):
            if target == format { return (target, nil) }
            let targets = cache[format] ?? Set(matrix.targets(for: format))
            cache[format] = targets
            guard targets.contains(target) else { return nil }
            return (target, ConversionRequest(source: format, target: target))
        case let .tool(id):
            guard let tool = tools[id], var request = tool.request(format) else { return nil }
            // One file in, one file out; passwords never live in a recipe.
            if request.options.pdf?.producesSeveralFiles == true || request.options.pdf?.secret != nil
                || request.options.passport?.printSheet == true || request.inputs != nil {
                return nil
            }
            request.source = format
            return (request.target, request)
        }
    }

    static func unique(_ formats: [FileFormat]) -> [FileFormat] {
        let set = Set(formats)
        return FileFormat.allCases.filter(set.contains)
    }

    /// "JPEG", "JPEG or PNG", "JPEG, PNG or 3 other kinds".
    public static func list(_ formats: [FileFormat]) -> String {
        let names = formats.map(\.displayName)
        switch names.count {
        case 0: return "file"
        case 1: return names[0]
        case 2, 3: return names.dropLast().joined(separator: ", ") + " or " + names.last!
        default: return names.prefix(2).joined(separator: ", ") + " or \(names.count - 2) other kinds"
        }
    }
}
