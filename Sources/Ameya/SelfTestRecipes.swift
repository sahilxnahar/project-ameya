import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO

/// Self-test for recipes: several worker jobs in a row, in-between files cleaned up, only the
/// final file written, and the starter recipes checked against this Mac.
extension SelfTest.Checker {
    mutating func checkRecipes() async {
        let catalog = ToolCatalog(writable: FileFormat.systemWritable())
        let planner = catalog.recipePlanner(matrix: ConversionMatrix(writable: FileFormat.systemWritable()))

        for starter in Recipe.starters {
            let analysis = planner.analyse(starter)
            reportRecipe(analysis.isValid, "starter \"\(starter.name)\" fits together",
                         analysis.problem?.errorDescription ?? "accepts nothing")
        }

        // PNG → Make it smaller → JPEG → Remove location.
        let recipe = Recipe(name: "Self-test", steps: [.tool("image.smaller"), .convert(.jpeg), .tool("image.removeLocation")])
        do {
            let source = directory.appendingPathComponent("wide.png")
            let original = try SelfTest.makeWidePNGWithLocation()
            try original.write(to: source)
            guard let steps = planner.plan(recipe, for: .png), steps.count == 3 else {
                reportRecipe(false, "png recipe plan", "expected 3 steps")
                return
            }
            let scratch = directory.appendingPathComponent("recipe-scratch", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("wide (edited).jpg")
            let result = try await RecipeRunner.run(steps, input: source, destination: destination,
                                                    temporaryDirectory: scratch,
                                                    execute: RecipeJobs.execute(worker: runner.executable))
            let size = SelfTest.pixelSize(destination)
            let noGPS = SelfTest.properties(destination)[kCGImagePropertyGPSDictionary] == nil
            let ok = FileFormat.detect(at: destination) == .jpeg && max(size.0, size.1) == 2048 && noGPS
                && result.notes.contains(.resized)
            reportRecipe(ok, "png -> smaller -> jpeg -> no location",
                         "got \(size.0)×\(size.1), GPS removed: \(noGPS), notes: \(result.notes)")
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? ["?"]
            reportRecipe(leftovers.isEmpty, "recipe leaves no in-between files", "found \(leftovers)")
            reportRecipe((try? Data(contentsOf: source)) == original, "recipe leaves the original unchanged", "changed")
        } catch {
            reportRecipe(false, "png recipe", error.localizedDescription)
        }
    }

    private mutating func reportRecipe(_ passed: Bool, _ label: String, _ problem: String) {
        print(passed ? "PASS recipe \(label)" : "FAIL recipe \(label): \(problem)")
        if !passed { allPassed = false }
    }
}

extension SelfTest {
    /// A 3000×1500 PNG carrying GPS coordinates.
    static func makeWidePNGWithLocation() throws -> Data {
        guard let context = CGContext(
            data: nil, width: 3000, height: 1500, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw CocoaError(.featureUnsupported) }
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
        guard let image = context.makeImage() else { throw CocoaError(.featureUnsupported) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.featureUnsupported)
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 19.07, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 72.87, kCGImagePropertyGPSLongitudeRef: "E"],
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
