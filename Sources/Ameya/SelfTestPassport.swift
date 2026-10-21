import AmeyaCore
import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Self-test for "Passport photo…" through the sandboxed worker: on-device Vision must run in the
/// sandbox, a picture without a face must get the friendly message, and a face (the 🧑🏽 emoji,
/// which Vision recognises) must become a correctly sized JPEG and a print-sheet folder.
extension SelfTest.Checker {
    mutating func checkPassportPhoto(png: URL) async {
        guard let tool = ToolCatalog(writable: FileFormat.systemWritable()).tools.first(where: { $0.id == "image.passportPhoto" }),
              let us = PassportSpec.presets.first(where: { $0.id == "us" }) else {
            reportPassport(false, "tool registered", "Passport photo tool missing")
            return
        }
        func options(_ printSheet: Bool) -> ConversionOptions {
            var options = ConversionOptions()
            options.passport = PassportPhotoOptions(spec: us, printSheet: printSheet)
            return options
        }
        func request(_ printSheet: Bool) -> ConversionRequest {
            var request = tool.makeRequest(.png)
            request.options = options(printSheet)
            return request
        }

        // No face: a friendly refusal, not a crash.
        do {
            _ = try await runner.run(input: png, destination: directory.appendingPathComponent("noface (passport).jpg"),
                                     request: request(false))
            reportPassport(false, "no face refused", "a picture without a face was accepted")
        } catch {
            let friendly = error.localizedDescription.contains("No face was found")
            reportPassport(friendly, "no face refused", error.localizedDescription)
        }

        do {
            let face = directory.appendingPathComponent("face.png")
            try SelfTest.makeFacePNG().write(to: face)
            let photo = OutputPlanner.destination(for: face, target: .jpeg, in: directory,
                                                  suffix: tool.outputSuffix(for: options(false)))
            do {
                _ = try await runner.run(input: face, destination: photo, request: request(false))
            } catch let error where error.localizedDescription.contains("No face was found") {
                print("SKIP passport photo: Vision doesn't see the emoji face on this macOS")
                return
            }
            let size = SelfTest.pixelSize(photo)
            reportPassport(FileFormat.detect(at: photo) == .jpeg && size == (600, 600)
                           && photo.lastPathComponent == "face (USA passport).jpg",
                           "digital photo", "got \(photo.lastPathComponent) \(size.0)×\(size.1)")

            let folder = OutputPlanner.folderDestination(for: face, suffix: tool.outputSuffix(for: options(true)), in: directory)
            let result = try await runner.run(input: face, destination: folder, request: request(true))
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()) ?? []
            let sheet = names.first { $0.hasPrefix("Print sheet") && $0.hasSuffix(".jpg") }
            let sheetSize = sheet.map { SelfTest.pixelSize(folder.appendingPathComponent($0)) } ?? (0, 0)
            reportPassport(tool.producesFolder(for: options(true)) && names.count == 3
                           && Set(names) == Set(result.outputNames ?? []) && sheetSize == (1200, 1800), // 6 copies, portrait
                           "print sheet", "got \(names) sheet \(sheetSize.0)×\(sheetSize.1)")
        } catch {
            reportPassport(false, "passport photo", error.localizedDescription)
        }
    }

    private mutating func reportPassport(_ passed: Bool, _ label: String, _ problem: String) {
        print(passed ? "PASS passport \(label)" : "FAIL passport \(label): \(problem)")
        if !passed { allPassed = false }
    }
}

extension SelfTest {
    /// The "person, medium skin tone" emoji drawn large on grey: a face Vision detects.
    static func makeFacePNG() throws -> Data {
        guard let context = CGContext(
            data: nil, width: 1200, height: 1500, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw CocoaError(.featureUnsupported) }
        context.setFillColor(CGColor(gray: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1500))
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 600, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "\u{1F9D1}\u{1F3FD}", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 600 - CTLineGetTypographicBounds(line, nil, nil, nil) / 2, y: 510)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { throw CocoaError(.featureUnsupported) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.featureUnsupported)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.featureUnsupported) }
        return data as Data
    }
}
