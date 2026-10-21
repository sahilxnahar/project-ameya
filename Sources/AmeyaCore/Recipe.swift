import Foundation

// Recipes: a name, an icon and an ordered list of steps, each a plain conversion or a one-click
// tool. Each step runs as a normal worker job (RecipeRunner). Shared as `.ameyarecipe` files.

/// One thing a recipe does to the file the previous step made.
public enum RecipeStep: Sendable, Equatable, Hashable {
    /// Convert to this format. Skipped when the file already is in it.
    case convert(FileFormat)
    /// Run a one-click tool from the catalog, by its stable id (e.g. "image.removeLocation").
    case tool(String)
}

extension RecipeStep: Codable {
    private enum Key: String, CodingKey { case convert, tool }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        if let format = try container.decodeIfPresent(FileFormat.self, forKey: .convert) {
            self = .convert(format)
        } else {
            self = .tool(try container.decode(String.self, forKey: .tool))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case let .convert(format): try container.encode(format, forKey: .convert)
        case let .tool(id): try container.encode(id, forKey: .tool)
        }
    }
}

public struct Recipe: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// SF Symbol name, one of `Recipe.symbols`.
    public var symbol: String
    public var steps: [RecipeStep]

    public init(id: UUID = UUID(), name: String, symbol: String = Recipe.symbols[0], steps: [RecipeStep]) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.steps = steps
    }

    /// The catalog id of the tool this recipe becomes.
    public var toolID: String { "recipe.\(id.uuidString)" }

    public static let maxSteps = 12
    public static let maxNameLength = 60

    /// Friendly icons offered in the editor. Imported recipes must use one of these.
    public static let symbols = [
        "wand.and.stars", "sparkles", "photo", "camera", "doc.text", "doc.viewfinder", "film",
        "play.rectangle", "music.note", "envelope", "paperplane", "bubble.left", "scissors",
        "archivebox", "tray.and.arrow.down", "folder", "lock", "leaf", "star", "bolt", "heart", "gift",
    ]

    /// Recipes every new Ameya starts with. Fixed ids, so they are only added once.
    public static let starters: [Recipe] = [
        Recipe(id: UUID(uuidString: "6A3C3B1E-0001-4D6E-9A11-A3E7A0000001")!,
               name: "iPhone photos → small JPEGs without location", symbol: "camera",
               steps: [.convert(.jpeg), .tool("image.smaller"), .tool("image.removeLocation")]),
        // Compress before recognising text: the compressor keeps pages with text as they are.
        Recipe(id: UUID(uuidString: "6A3C3B1E-0002-4D6E-9A11-A3E7A0000002")!,
               name: "Scans → searchable PDF under 2 MB", symbol: "doc.viewfinder",
               steps: [.convert(.pdf), .tool("pdf.under2MB"), .tool("pdf.searchable")]),
        Recipe(id: UUID(uuidString: "6A3C3B1E-0003-4D6E-9A11-A3E7A0000003")!,
               name: "Screen recording → GIF for chat", symbol: "bubble.left",
               steps: [.tool("video.smaller"), .convert(.gif)]),
    ]
}

/// Why an `.ameyarecipe` file was refused. Messages are plain and say what to do.
public enum RecipeImportError: Error, Equatable, LocalizedError {
    case tooLarge
    case notJSON
    case notARecipe
    case newerVersion(Int)
    case unsupportedVersion
    case unexpectedField(String)
    case badName
    case badSymbol(String)
    case noSteps
    case tooManySteps
    case badStep(Int)
    case unknownFormat(step: Int, value: String)
    case badToolID(step: Int)

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "This file is too large to be a recipe."
        case .notJSON, .notARecipe: "This isn't an Ameya recipe file."
        case let .newerVersion(version): "This recipe was made by a newer Ameya (recipe version \(version)). Update Ameya to use it."
        case .unsupportedVersion: "This recipe file has a version Ameya doesn't know."
        case let .unexpectedField(name): "This recipe has a field Ameya doesn't know (\"\(name)\"), so it wasn't imported."
        case .badName: "This recipe needs a name of 1 to \(Recipe.maxNameLength) characters."
        case let .badSymbol(name): "This recipe uses an icon Ameya doesn't offer (\"\(name)\")."
        case .noSteps: "This recipe has no steps."
        case .tooManySteps: "This recipe has more than \(Recipe.maxSteps) steps."
        case let .badStep(step): "Step \(step) of this recipe isn't something Ameya can do."
        case let .unknownFormat(step, value): "Step \(step) converts to \"\(value)\", a format Ameya doesn't know."
        case let .badToolID(step): "Step \(step) names a tool in a way Ameya doesn't understand."
        }
    }
}

/// The `.ameyarecipe` file: versioned JSON, read strictly (unknown fields are refused).
///
///     {"format": "ameya-recipe", "version": 1,
///      "recipe": {"name": "…", "symbol": "camera",
///                 "steps": [{"convert": "jpeg"}, {"tool": "image.removeLocation"}]}}
///
/// Ids are not stored: an imported recipe always gets a new one. Whether each tool exists on
/// this Mac, and whether the steps fit together, is checked afterwards by `RecipePlanner`.
public enum RecipeFile {
    public static let fileExtension = "ameyarecipe"
    public static let typeIdentifier = "io.github.sahilxnahar.ameya.recipe"
    public static let formatName = "ameya-recipe"
    public static let currentVersion = 1
    public static let maxBytes = 64 * 1024

    public static func encode(_ recipe: Recipe) throws -> Data {
        let steps: [[String: String]] = recipe.steps.map { step in
            switch step {
            case let .convert(format): ["convert": format.rawValue]
            case let .tool(id): ["tool": id]
            }
        }
        let object: [String: Any] = [
            "format": formatName,
            "version": currentVersion,
            "recipe": ["name": recipe.name, "symbol": recipe.symbol, "steps": steps],
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    public static func decode(_ data: Data) throws -> Recipe {
        guard data.count <= maxBytes else { throw RecipeImportError.tooLarge }
        guard let any = try? JSONSerialization.jsonObject(with: data) else { throw RecipeImportError.notJSON }
        guard let top = any as? [String: Any], top["format"] as? String == formatName else {
            throw RecipeImportError.notARecipe
        }
        try onlyKnownKeys(top, ["format", "version", "recipe"])
        // JSON `true` also bridges to 1, so make sure the number really is a number.
        guard let number = top["version"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let version = top["version"] as? Int else { throw RecipeImportError.unsupportedVersion }
        if version > currentVersion { throw RecipeImportError.newerVersion(version) }
        guard version == currentVersion else { throw RecipeImportError.unsupportedVersion }
        guard let body = top["recipe"] as? [String: Any] else { throw RecipeImportError.notARecipe }
        try onlyKnownKeys(body, ["name", "symbol", "steps"])

        guard let rawName = body["name"] as? String else { throw RecipeImportError.badName }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= Recipe.maxNameLength, !name.contains(where: \.isNewline) else {
            throw RecipeImportError.badName
        }
        guard let symbol = body["symbol"] as? String else { throw RecipeImportError.badSymbol("") }
        guard Recipe.symbols.contains(symbol) else { throw RecipeImportError.badSymbol(String(symbol.prefix(40))) }
        guard let rawSteps = body["steps"] as? [Any] else { throw RecipeImportError.noSteps }
        guard !rawSteps.isEmpty else { throw RecipeImportError.noSteps }
        guard rawSteps.count <= Recipe.maxSteps else { throw RecipeImportError.tooManySteps }

        var steps: [RecipeStep] = []
        for (index, raw) in rawSteps.enumerated() {
            let number = index + 1
            guard let step = raw as? [String: Any], step.count == 1, let (key, value) = step.first,
                  let text = value as? String else { throw RecipeImportError.badStep(number) }
            switch key {
            case "convert":
                guard let format = FileFormat(rawValue: text), !Self.unusableTargets.contains(format) else {
                    throw RecipeImportError.unknownFormat(step: number, value: String(text.prefix(40)))
                }
                steps.append(.convert(format))
            case "tool":
                guard isWellFormedToolID(text) else { throw RecipeImportError.badToolID(step: number) }
                steps.append(.tool(text))
            default:
                throw RecipeImportError.badStep(number)
            }
        }
        return Recipe(name: name, symbol: symbol, steps: steps)
    }

    /// Placeholders, not formats anyone converts to.
    static let unusableTargets: Set<FileFormat> = [.decompressed, .other]

    /// Letters, digits and dots, like "image.removeLocation". Recipes can't nest other recipes.
    public static func isWellFormedToolID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && !id.hasPrefix("recipe.")
            && id.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." }
    }

    private static func onlyKnownKeys(_ object: [String: Any], _ known: Set<String>) throws {
        if let extra = object.keys.sorted().first(where: { !known.contains($0) }) {
            throw RecipeImportError.unexpectedField(String(extra.prefix(40)))
        }
    }
}
