import Foundation
import Testing
@testable import AmeyaCore

/// Stand-ins for the app's tools, shaped like the real ones.
enum FakeTools {
    static func keepImage(_ id: String, _ title: String, _ edits: ImageEdits) -> RecipeToolInfo {
        RecipeToolInfo(id: id, title: title) { format in
            guard format.family == .image, !format.isIcon else { return nil }
            return ConversionRequest(source: format, target: format, options: ConversionOptions(image: edits))
        }
    }

    static func pdf(_ id: String, _ title: String, _ action: PDFAction) -> RecipeToolInfo {
        RecipeToolInfo(id: id, title: title) { format in
            format == .pdf ? ConversionRequest(source: format, target: .pdf, options: ConversionOptions(pdf: action)) : nil
        }
    }

    static var all: [RecipeToolInfo] { [
        keepImage("image.smaller", "Make it smaller", ImageEdits(maxPixelSize: 2048)),
        keepImage("image.removeLocation", "Remove location", ImageEdits(metadata: .removeLocation)),
        pdf("pdf.under2MB", "PDF under 2 MB", .compress(quality: 0.7, targetBytes: 2_000_000)),
        pdf("pdf.searchable", "Make PDF searchable", .ocr(languages: nil)),
        pdf("pdf.split", "Split into pages", .splitEveryPage),
        pdf("pdf.protect", "Password-protect PDF…", .protect(password: "")),
        RecipeToolInfo(id: "video.smaller", title: "Make it smaller (720p)") { format in
            format.family == .video
                ? ConversionRequest(source: format, target: format, options: ConversionOptions(video: VideoEdits(maxPixelSize: 1280)))
                : nil
        },
    ] }

    static var planner: RecipePlanner { RecipePlanner(matrix: ConversionMatrix(writable: Set(FileFormat.allCases)), tools: all) }
}

@Suite("Recipe chains")
struct RecipeValidationTests {
    let planner = FakeTools.planner
    let photo = Recipe(name: "Photo", steps: [.tool("image.smaller"), .convert(.jpeg), .tool("image.removeLocation")])

    @Test("A fitting chain lists what it takes and makes")
    func validChain() throws {
        let analysis = planner.analyse(photo)
        #expect(analysis.isValid)
        #expect(analysis.accepts.contains(.png) && analysis.accepts.contains(.heic) && analysis.accepts.contains(.jpeg))
        #expect(!analysis.accepts.contains(.pdf) && !analysis.accepts.contains(.ico))
        #expect(analysis.produces == [.jpeg])
    }

    @Test("Planning makes one request per step, each starting where the last ended")
    func plan() throws {
        let steps = try #require(planner.plan(photo, for: .png))
        #expect(steps.map(\.number) == [1, 2, 3])
        #expect(steps.map(\.request.source) == [.png, .png, .jpeg])
        #expect(steps.map(\.request.target) == [.png, .jpeg, .jpeg])
        #expect(steps[0].request.options.image?.maxPixelSize == 2048)
        #expect(steps[2].request.options.image?.metadata == .removeLocation)
        #expect(steps[1].title == "Convert to JPEG")
    }

    @Test("A conversion to the format the file already has is skipped")
    func skipsSameFormat() throws {
        let steps = try #require(planner.plan(photo, for: .jpeg))
        #expect(steps.map(\.number) == [1, 3])
        let copy = Recipe(name: "Copy", steps: [.convert(.jpeg)])
        #expect(planner.plan(copy, for: .jpeg) == [])
        #expect(planner.output(of: copy, for: .jpeg) == .jpeg)
        #expect(planner.plan(photo, for: .mp3) == nil)
    }

    @Test("A step that can't follow the one before is refused, naming it")
    func stepDoesNotFit() throws {
        let recipe = Recipe(name: "Bad", steps: [.convert(.mp3), .tool("image.smaller")])
        let analysis = planner.analyse(recipe)
        #expect(!analysis.isValid && analysis.accepts.isEmpty)
        guard case let .stepDoesNotFit(step, title, after) = analysis.problem else {
            Issue.record("expected stepDoesNotFit, got \(String(describing: analysis.problem))")
            return
        }
        #expect(step == 2 && title == "Make it smaller" && after == [.mp3])
        #expect(analysis.problem?.errorDescription == "Step 2 (Make it smaller) can't work on the MP3 that step 1 makes.")
    }

    @Test("Several files out, passwords, unknown tools and bad lengths are refused")
    func refusals() {
        let split = planner.analyse(Recipe(name: "Split", steps: [.tool("pdf.split")]))
        #expect(split.problem == .stepDoesNotFit(step: 1, title: "Split into pages", after: []))
        #expect(split.problem?.errorDescription?.contains("doesn't work on any kind of file") == true)
        #expect(!planner.analyse(Recipe(name: "Lock", steps: [.convert(.pdf), .tool("pdf.protect")])).isValid)
        #expect(planner.analyse(Recipe(name: "?", steps: [.tool("nope.tool")])).problem == .unknownTool(step: 1, id: "nope.tool"))
        #expect(planner.analyse(Recipe(name: "Empty", steps: [])).problem == .noSteps)
        let long = Recipe(name: "Long", steps: Array(repeating: .convert(.png), count: Recipe.maxSteps + 1))
        #expect(planner.analyse(long).problem == .tooManySteps)
    }

    @Test("The planner's quick conversion check agrees with the matrix")
    func matchesMatrix() {
        let matrix = ConversionMatrix(writable: [.jpeg, .png, .pdf, .gif, .mp4, .txt])
        let planner = RecipePlanner(matrix: matrix, tools: [])
        for source in [FileFormat.heic, .png, .pdf, .mov, .mp3, .csv, .jpeg] {
            #expect(Set(matrix.targets(for: source)) == Set(RecipePlanner.candidateSources.filter { planner.canConvert(source, to: $0) }))
        }
        #expect(planner.reachableTargets.allSatisfy(matrix.writable.contains))
    }

    @Test("The starter recipes fit together", arguments: Recipe.starters)
    func starters(recipe: Recipe) {
        let analysis = planner.analyse(recipe)
        #expect(analysis.isValid, "\(recipe.name): \(String(describing: analysis.problem))")
    }

    @Test func startersTakeWhatTheirNamesSay() {
        #expect(planner.analyse(Recipe.starters[0]).accepts.contains(.heic))
        #expect(planner.analyse(Recipe.starters[0]).produces == [.jpeg])
        #expect(Set(planner.analyse(Recipe.starters[1]).accepts).isSuperset(of: [.pdf, .jpeg, .png]))
        #expect(planner.analyse(Recipe.starters[1]).produces == [.pdf])
        #expect(planner.analyse(Recipe.starters[2]).accepts.contains(.mov))
        #expect(planner.analyse(Recipe.starters[2]).produces == [.gif])
    }
}

@Suite("Recipe files")
struct RecipeFileTests {
    let recipe = Recipe(name: "Tidy photos", symbol: "camera", steps: [.convert(.jpeg), .tool("image.removeLocation")])

    func json(_ text: String) -> Data { Data(text.utf8) }
    func decodeError(_ text: String) -> RecipeImportError? {
        do { _ = try RecipeFile.decode(json(text)); return nil } catch { return error as? RecipeImportError }
    }
    func wrap(_ body: String, version: String = "1") -> String {
        #"{"format":"ameya-recipe","version":\#(version),"recipe":\#(body)}"#
    }

    @Test("Export then import gives the same recipe with a new id")
    func roundTrip() throws {
        let decoded = try RecipeFile.decode(try RecipeFile.encode(recipe))
        #expect(decoded.name == recipe.name && decoded.symbol == recipe.symbol && decoded.steps == recipe.steps)
        #expect(decoded.id != recipe.id)
        let text = String(decoding: try RecipeFile.encode(recipe), as: UTF8.self)
        #expect(text.contains(#""format" : "ameya-recipe""#) && text.contains(#""convert" : "jpeg""#))
    }

    @Test("Stored recipes keep their id and steps")
    func codable() throws {
        let decoded = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(recipe))
        #expect(decoded == recipe)
    }

    @Test("Strict import refuses anything unexpected")
    func strictErrors() {
        let steps = #"[{"convert":"jpeg"}]"#
        #expect(decodeError("not json") == .notJSON)
        #expect(decodeError(#"{"format":"other","version":1}"#) == .notARecipe)
        #expect(decodeError(wrap(#"{"name":"A","symbol":"camera","steps":\#(steps)}"#, version: "2")) == .newerVersion(2))
        #expect(decodeError(wrap(#"{"name":"A","symbol":"camera","steps":\#(steps)}"#, version: "true")) == .unsupportedVersion)
        #expect(decodeError(wrap(#"{"name":"A","symbol":"camera","steps":\#(steps)}"#, version: "0")) == .unsupportedVersion)
        #expect(decodeError(#"{"format":"ameya-recipe","version":1,"recipe":{"name":"A","symbol":"camera","steps":\#(steps)},"extra":1}"#)
            == .unexpectedField("extra"))
        #expect(decodeError(wrap(#"{"name":"A","symbol":"camera","steps":\#(steps),"id":"x"}"#)) == .unexpectedField("id"))
        #expect(decodeError(wrap(#"{"name":"  ","symbol":"camera","steps":\#(steps)}"#)) == .badName)
        #expect(decodeError(wrap(#"{"name":"\#(String(repeating: "x", count: 61))","symbol":"camera","steps":\#(steps)}"#)) == .badName)
        #expect(decodeError(wrap(#"{"name":"A","symbol":"trash.fill","steps":\#(steps)}"#)) == .badSymbol("trash.fill"))
        #expect(decodeError(wrap(#"{"name":"A","symbol":"camera","steps":[]}"#)) == .noSteps)
        let thirteen = "[" + Array(repeating: #"{"convert":"png"}"#, count: 13).joined(separator: ",") + "]"
        #expect(decodeError(wrap(#"{"name":"A","symbol":"camera","steps":\#(thirteen)}"#)) == .tooManySteps)
        #expect(decodeError(wrap(#"{"name":"A","symbol":"camera","steps":[{"convert":"jpeg","tool":"x"}]}"#)) == .badStep(1))
        #expect(decodeError(wrap(#"{"name":"A","symbol":"camera","steps":[{"run":"x"}]}"#)) == .badStep(1))
        #expect(decodeError(wrap(#"{"name":"A","symbol":"camera","steps":[{"convert":3}]}"#)) == .badStep(1))
        #expect(decodeError(wrap(#"{"name":"A","symbol":"camera","steps":[{"convert":"jpeg"},{"convert":"bmpx"}]}"#))
            == .unknownFormat(step: 2, value: "bmpx"))
        #expect(decodeError(wrap(#"{"name":"A","symbol":"camera","steps":[{"convert":"other"}]}"#))
            == .unknownFormat(step: 1, value: "other"))
        #expect(decodeError(wrap(#"{"name":"A","symbol":"camera","steps":[{"tool":"recipe.abc"}]}"#)) == .badToolID(step: 1))
        #expect(decodeError(wrap(#"{"name":"A","symbol":"camera","steps":[{"tool":"rm -rf"}]}"#)) == .badToolID(step: 1))
        #expect(decodeError(String(repeating: " ", count: RecipeFile.maxBytes + 1)) == .tooLarge)
    }

    @Test("Every refusal has a plain message")
    func messages() {
        let errors: [RecipeImportError] = [.tooLarge, .notJSON, .notARecipe, .newerVersion(3), .unsupportedVersion,
                                           .unexpectedField("x"), .badName, .badSymbol("x"), .noSteps, .tooManySteps,
                                           .badStep(1), .unknownFormat(step: 1, value: "x"), .badToolID(step: 1)]
        for error in errors { #expect(error.errorDescription?.isEmpty == false) }
        #expect(RecipeImportError.newerVersion(3).errorDescription?.contains("newer Ameya") == true)
    }
}
