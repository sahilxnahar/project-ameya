import AmeyaCore
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
@testable import AmeyaEngines

/// Generated pictures and pixel reading for the photo tool tests.
enum PhotoFixture {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Draws with a top-left origin.
    static func image(width: Int, height: Int, alpha: Bool = false, _ draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        return context.makeImage()!
    }

    static func solid(_ r: Double, _ g: Double, _ b: Double, width: Int = 64, height: Int = 64) -> CGImage {
        image(width: width, height: height) { context in
            context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Left to right from black to white.
    static func ramp(width: Int = 128, height: Int = 32) -> CGImage {
        image(width: width, height: height) { context in
            for x in 0..<width {
                let v = Double(x) / Double(width - 1)
                context.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1))
                context.fill(CGRect(x: x, y: 0, width: 1, height: height))
            }
        }
    }

    /// A 2-pixel black and white checkerboard: detail that blurring or pixelating must destroy.
    static func checkerboard(width: Int = 200, height: Int = 200) -> CGImage {
        image(width: width, height: height) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for y in stride(from: 0, to: height, by: 2) {
                for x in stride(from: (y / 2) % 2 * 2, to: width, by: 4) { context.fill(CGRect(x: x, y: y, width: 2, height: 2)) }
            }
        }
    }

    /// Black text on white, drawn large.
    static func text(_ lines: [String], width: Int = 1400, height: Int = 700, size: CGFloat = 90) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        for (index, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]))
            context.textPosition = CGPoint(x: 60, y: Double(height) - 160 - Double(index) * size * 2.2)
            CTLineDraw(line, context)
        }
        return context.makeImage()!
    }

    struct Pixels {
        let width, height: Int
        let bytes: [UInt8]
        /// sRGB 0…255 and alpha at (x, y), origin top-left.
        func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let i = (y * width + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
        }

        func mean(_ channel: Int, in rect: CGRect? = nil) -> Double {
            let rect = rect ?? CGRect(x: 0, y: 0, width: width, height: height)
            var total = 0.0, count = 0.0
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) { total += Double(bytes[(y * width + x) * 4 + channel]); count += 1 }
            }
            return total / count
        }

        func spread(in rect: CGRect) -> Double {
            let average = mean(0, in: rect)
            var total = 0.0, count = 0.0
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let d = Double(bytes[(y * width + x) * 4]) - average
                    total += d * d
                    count += 1
                }
            }
            return (total / count).squareRoot()
        }
    }

    static func pixels(_ image: CGImage) -> Pixels {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: sRGB,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Pixels(width: image.width, height: image.height, bytes: bytes)
    }

    static func encode(_ image: CGImage, as type: String = "public.png", properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func decode(_ data: Data) -> CGImage {
        CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
    }

    /// Runs the image pipeline with these edits and returns the decoded output.
    static func run(_ image: CGImage, _ edits: ImageEdits, from source: FileFormat = .png, to target: FileFormat = .png)
        throws -> (CGImage, ConversionResult, Data) {
        let input = source == .jpeg ? encode(image, as: "public.jpeg") : encode(image)
        let (data, result) = try ImageConverter.convert(
            input, request: ConversionRequest(source: source, target: target, options: ConversionOptions(image: edits)))
        return (decode(data), result, data)
    }
}

@Suite("Photo tools: adjustments")
struct PhotoAdjustmentTests {
    let base = PhotoFixture.solid(0.5, 0.45, 0.4)

    func adjusted(_ a: PhotoAdjustments, _ image: CGImage? = nil) throws -> PhotoFixture.Pixels {
        PhotoFixture.pixels(try PhotoRender.adjusted(image ?? base, a))
    }

    @Test func exposureBrightensAndDarkens() throws {
        let before = PhotoFixture.pixels(base).mean(1)
        #expect(try adjusted(PhotoAdjustments(exposure: 0.5)).mean(1) > before + 10)
        #expect(try adjusted(PhotoAdjustments(exposure: -0.5)).mean(1) < before - 10)
    }

    @Test func warmthAndTint() throws {
        let before = PhotoFixture.pixels(base)
        let warm = try adjusted(PhotoAdjustments(warmth: 0.6)), cool = try adjusted(PhotoAdjustments(warmth: -0.6))
        let balance = { (p: PhotoFixture.Pixels) in p.mean(0) - p.mean(2) }
        #expect(balance(warm) > balance(before) + 5)
        #expect(balance(cool) < balance(before) - 5)
        let green = { (p: PhotoFixture.Pixels) in p.mean(1) - (p.mean(0) + p.mean(2)) / 2 }
        #expect(green(try adjusted(PhotoAdjustments(tint: 0.8))) < green(before) - 2)
        #expect(green(try adjusted(PhotoAdjustments(tint: -0.8))) > green(before) + 2)
    }

    @Test func saturation() throws {
        let colour = PhotoFixture.solid(0.7, 0.4, 0.3)
        let spread = { (p: PhotoFixture.Pixels) in p.mean(0) - p.mean(2) }
        let before = spread(PhotoFixture.pixels(colour))
        #expect(spread(try adjusted(PhotoAdjustments(saturation: 0.6), colour)) > before + 5)
        #expect(abs(spread(try adjusted(PhotoAdjustments(saturation: -1), colour))) < 3)
    }

    @Test func contrastHighlightsShadows() throws {
        let ramp = PhotoFixture.ramp()
        let original = PhotoFixture.pixels(ramp)
        let dark = CGRect(x: 20, y: 0, width: 8, height: 32), bright = CGRect(x: 100, y: 0, width: 8, height: 32)
        let contrast = try adjusted(PhotoAdjustments(contrast: 0.6), ramp)
        #expect(contrast.mean(0, in: bright) - contrast.mean(0, in: dark) > original.mean(0, in: bright) - original.mean(0, in: dark) + 10)
        #expect(try adjusted(PhotoAdjustments(shadows: 0.8), ramp).mean(0, in: dark) > original.mean(0, in: dark) + 5)
        #expect(try adjusted(PhotoAdjustments(highlights: -0.8), ramp).mean(0, in: bright) < original.mean(0, in: bright) - 5)
        #expect(try adjusted(PhotoAdjustments(highlights: 0.8), ramp).mean(0, in: bright) > original.mean(0, in: bright) + 3)
    }

    @Test func sharpnessAddsEdgeContrast() throws {
        let soft = PhotoFixture.image(width: 64, height: 32) { context in
            for x in 0..<64 {
                let v = min(max(Double(x - 30) / 4, 0), 1) * 0.6 + 0.2 // a slightly soft step
                context.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1))
                context.fill(CGRect(x: x, y: 0, width: 1, height: 32))
            }
        }
        let region = CGRect(x: 16, y: 8, width: 32, height: 16)
        #expect(try adjusted(PhotoAdjustments(sharpness: 1), soft).spread(in: region) > PhotoFixture.pixels(soft).spread(in: region) + 1)
    }

    @Test func vignetteDarkensCorners() throws {
        let grey = PhotoFixture.solid(0.6, 0.6, 0.6, width: 200, height: 200)
        let result = try adjusted(PhotoAdjustments(vignette: 1), grey)
        #expect(result.mean(0, in: CGRect(x: 0, y: 0, width: 10, height: 10)) < result.mean(0, in: CGRect(x: 95, y: 95, width: 10, height: 10)) - 15)
    }

    @Test func autoEnhanceAndPipeline() throws {
        let dull = PhotoFixture.image(width: 160, height: 120) { context in
            for x in 0..<160 {
                let v = 0.35 + 0.15 * Double(x) / 159 // a flat, low-contrast picture
                context.setFillColor(CGColor(srgbRed: v, green: v * 0.95, blue: v * 0.9, alpha: 1))
                context.fill(CGRect(x: x, y: 0, width: 1, height: 120))
            }
        }
        #expect(PhotoAdjustments(autoEnhance: false).isNeutral)
        let (output, result, _) = try PhotoFixture.run(base, ImageEdits.photo(adjustments: PhotoAdjustments(exposure: 0.4)), from: .jpeg, to: .jpeg)
        #expect(PhotoFixture.pixels(output).mean(1) > PhotoFixture.pixels(base).mean(1) + 5)
        #expect(result.notes.isEmpty)
        _ = try adjusted(PhotoAdjustments(autoEnhance: true), dull) // runs without failing; changes depend on Core Image
    }
}

@Suite("Photo tools: redaction")
struct RedactionTests {
    let box = UnitRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    let inside = CGRect(x: 50, y: 50, width: 100, height: 100)

    @Test(arguments: Redaction.Style.allCases)
    func coversTheBox(style: Redaction.Style) throws {
        let source = PhotoFixture.checkerboard()
        let result = PhotoFixture.pixels(try PhotoRender.redacted(source, Redaction(boxes: [box], style: style)))
        let original = PhotoFixture.pixels(source)
        #expect(original.spread(in: inside) > 100)
        if style == .black {
            for y in 50..<150 { for x in 50..<150 { #expect(result.at(x, y).r == 0, "pixel \(x),\(y)") } }
        } else {
            // Within the cover no checkerboard detail is left: neighbouring pixels barely differ.
            var steps = 0.0
            for y in 52..<148 { for x in 52..<148 { steps += Double(abs(result.at(x, y).r - result.at(x + 1, y).r)) } }
            #expect(steps / (96 * 96) < 8, "\(style) left detail behind")
        }
        // Outside stays as it was.
        #expect(result.at(10, 10) == original.at(10, 10))
        #expect(result.at(190, 190) == original.at(190, 190))
    }

    @Test func metadataAndThumbnailAreGone() throws {
        let photo = PhotoFixture.solid(0.3, 0.6, 0.8, width: 640, height: 480)
        let jpeg = PhotoFixture.encode(photo, as: "public.jpeg", properties: [
            kCGImageDestinationEmbedThumbnail: true,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Test camera"],
        ])
        #expect(Self.hasExif(jpeg), "the fixture should carry EXIF")
        #expect(Self.startOfImageMarkers(jpeg) >= 2)

        let request = ConversionRequest(source: .jpeg, target: .jpeg,
                                        options: ConversionOptions(image: ImageEdits.photo(redaction: Redaction(boxes: [box], style: .black))))
        let (output, result) = try ImageConverter.convert(jpeg, request: request)
        #expect(result.notes.contains(.redactionBurnedIn))
        #expect(Self.startOfImageMarkers(output) == 1, "a second JPEG (a thumbnail) is still inside")
        let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(output as CFData, nil)!, 0, nil) as? [CFString: Any] ?? [:]
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] == nil)
        #expect((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] == nil)
        #expect(!String(decoding: output, as: UTF8.self).contains("secret"))
    }

    /// An APP1 "Exif" segment (where cameras keep the embedded thumbnail).
    static func hasExif(_ data: Data) -> Bool {
        data.range(of: Data([0xFF, 0xE1])) != nil && data.range(of: Data("Exif\0\0".utf8)) != nil
    }

    /// JPEG start-of-image markers; entropy-coded data never contains FF D8, so each is a whole picture.
    static func startOfImageMarkers(_ data: Data) -> Int {
        let bytes = [UInt8](data)
        return (0..<bytes.count - 1).filter { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xD8 }.count
    }

    @Test func finders() throws {
        if FaceFixture.faceFound(FaceFixture.image()) {
            let faces = PhotoVision.faces(in: FaceFixture.image())
            #expect(faces.count == 1)
            if let face = faces.first { #expect(face.x < 0.5 && face.x + face.width > 0.5 && face.y < 0.5 && face.y + face.height > 0.5) }
        } else {
            print("Vision does not see the emoji face on this macOS; skipping face finding")
        }
        let picture = PhotoFixture.text(["Welcome to the harbour", "AB12 CDE"])
        let text = PhotoVision.text(in: picture)
        #expect(text.count >= 2)
        let plates = PhotoVision.numberPlates(in: picture)
        #expect(plates.count == 1)
        if let plate = plates.first { #expect(plate.y > 0.3) } // the second line, lower down
    }

    @Test func plateHeuristic() {
        #expect(PhotoVision.isPlateLike("AB12 CDE", width: 300, height: 80))
        #expect(PhotoVision.isPlateLike("KA-05-MX-1234", width: 500, height: 100))
        #expect(!PhotoVision.isPlateLike("Welcome", width: 300, height: 80))
        #expect(!PhotoVision.isPlateLike("ABCDEF", width: 300, height: 80)) // no digit
        #expect(!PhotoVision.isPlateLike("AB12 CDE", width: 100, height: 100)) // square
        #expect(!PhotoVision.isPlateLike("12", width: 300, height: 80))
    }
}

@Suite("Photo tools: layout")
struct PhotoLayoutTests {
    @Test func beautifyGeometry() throws {
        let picture = PhotoFixture.solid(0.1, 0.2, 0.9, width: 200, height: 100)
        let padded = try PhotoRender.beautified(picture, Beautify(padding: 0.1, backdrop: .snow, cornerRadius: 0, shadow: false))
        #expect((padded.width, padded.height) == (240, 140))
        let pixels = PhotoFixture.pixels(padded)
        #expect(pixels.at(2, 2).r > 240 && pixels.at(2, 2).a == 255) // snow backdrop
        #expect(pixels.at(120, 70).b > 200) // the picture, centred
        let framed = try PhotoRender.beautified(picture, Beautify(padding: 0.1, backdrop: .transparent, windowFrame: true))
        #expect((framed.width, framed.height) == (240, 162))
        let corners = PhotoFixture.pixels(framed)
        #expect(corners.at(0, 0).a == 0)
        #expect(corners.at(120, 31).r > 200 && corners.at(120, 31).b > 200) // the light title bar above the picture
        // Rounded corners leave the very corner of the picture transparent on a clear backdrop.
        let rounded = try PhotoRender.beautified(picture, Beautify(padding: 0, backdrop: .transparent, cornerRadius: 0.1, shadow: false))
        #expect(PhotoFixture.pixels(rounded).at(0, 0).a == 0)
    }

    @Test(arguments: [Watermark.Position.topLeft, .bottomRight, .centre])
    func textWatermarkPlacement(position: Watermark.Position) throws {
        let black = PhotoFixture.solid(0, 0, 0, width: 400, height: 200)
        let marked = PhotoFixture.pixels(try PhotoRender.watermarked(
            black, Watermark(text: "AMEYA", position: position, opacity: 1, size: 0.3), logo: nil))
        let quadrants: [Watermark.Position: CGRect] = [
            .topLeft: CGRect(x: 0, y: 0, width: 200, height: 100), .bottomRight: CGRect(x: 200, y: 100, width: 200, height: 100),
            .centre: CGRect(x: 120, y: 60, width: 160, height: 80),
        ]
        let target = quadrants[position]!
        #expect(marked.mean(0, in: target) > 10)
        for (other, rect) in quadrants where other != position && !rect.intersects(target) {
            #expect(marked.mean(0, in: rect) < 1, "\(position) also drew in \(other)")
        }
    }

    @MainActor @Test func logoWatermarkThroughEngine() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("photo-logo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let photo = scratch.appendingPathComponent("0.png"), logo = scratch.appendingPathComponent("1.png")
        try PhotoFixture.encode(PhotoFixture.solid(1, 1, 1, width: 400, height: 300)).write(to: photo)
        try PhotoFixture.encode(PhotoFixture.solid(1, 0, 0, width: 100, height: 50)).write(to: logo)
        let edits = ImageEdits.photo(watermark: Watermark(useLogo: true, position: .topLeft, opacity: 1, size: 0.25))
        let request = ConversionRequest(source: .png, target: .png, options: ConversionOptions(image: edits), inputs: [.png, .png])
        let (outputs, _) = try await Engine.run(inputs: [photo, logo], request: request, scratch: scratch) { _ in }
        let pixels = PhotoFixture.pixels(PhotoFixture.decode(try Data(contentsOf: outputs[0])))
        // 100 × 50 px logo at a 9 px margin: red near the top left, white elsewhere.
        #expect(pixels.at(50, 30).r > 240 && pixels.at(50, 30).g < 20)
        #expect(pixels.at(350, 250) == (255, 255, 255, 255))
        await #expect(throws: (any Error).self) {
            _ = try await Engine.run(inputs: [photo], request: ConversionRequest(source: .png, target: .png, options: ConversionOptions(image: edits)),
                                     scratch: scratch) { _ in }
        }
    }

    @Test func annotations() throws {
        let white = PhotoFixture.solid(1, 1, 1, width: 300, height: 200)
        let marks = [
            Annotation(kind: .rectangle, start: PhotoPoint(x: 0.1, y: 0.1), end: PhotoPoint(x: 0.4, y: 0.5), colour: .red),
            Annotation(kind: .step, start: PhotoPoint(x: 0.8, y: 0.8), end: PhotoPoint(x: 0.8, y: 0.8), number: 1, colour: .blue),
            Annotation(kind: .highlight, start: PhotoPoint(x: 0.5, y: 0.1), end: PhotoPoint(x: 0.9, y: 0.2), colour: .yellow),
            Annotation(kind: .arrow, start: PhotoPoint(x: 0.1, y: 0.9), end: PhotoPoint(x: 0.5, y: 0.9), colour: .green),
            Annotation(kind: .text, start: PhotoPoint(x: 0.5, y: 0.4), end: PhotoPoint(x: 0.5, y: 0.4), text: "Hi", colour: .black),
        ]
        let pixels = PhotoFixture.pixels(try PhotoRender.annotated(white, marks))
        let edge = pixels.at(30, 60) // left edge of the rectangle
        #expect(edge.r > 200 && edge.g < 90)
        #expect(pixels.at(60, 60) == (255, 255, 255, 255)) // inside the rectangle stays clear
        #expect(pixels.at(240, 160).b > 200 && pixels.at(240, 160).r < 120 || pixels.at(240, 160).r > 200) // circle or its number
        #expect(pixels.at(210, 30).b < 200 && pixels.at(210, 30).r > 240) // yellow highlight
        #expect(pixels.at(90, 180).g > 120 && pixels.at(90, 180).r < 120) // the arrow's shaft
    }
}

@Suite("Photo tools: background removal")
struct BackgroundRemovalTests {
    @Test func liftsTheSubject() throws {
        let face = FaceFixture.image(canvas: (900, 900), pointSize: 500)
        let request = ConversionRequest(source: .png, target: .png,
                                        options: ConversionOptions(image: ImageEdits.photo(removeBackground: BackgroundRemoval())))
        let output: Data
        do {
            (output, _) = try ImageConverter.convert(FaceFixture.png(face), request: request)
        } catch let error as ConversionError {
            print("Vision found no subject on this Mac (\(error.localizedDescription)); skipping")
            return
        }
        let pixels = PhotoFixture.pixels(PhotoFixture.decode(output))
        #expect(pixels.at(5, 5).a == 0, "the plain background should be transparent")
        #expect(pixels.at(450, 420).a == 255, "the subject should stay")

        var sticker = request
        sticker.options.image?.removeBackground = BackgroundRemoval(subjects: .largest, sticker: true)
        let (stickerData, notes) = try ImageConverter.convert(FaceFixture.png(face), request: sticker)
        let stickerImage = PhotoFixture.decode(stickerData)
        #expect(stickerImage.width > 900 && notes.notes.contains(.backgroundRemoved))
    }

    @Test func plainPictureHasNoSubject() throws {
        let request = ConversionRequest(source: .png, target: .png,
                                        options: ConversionOptions(image: ImageEdits.photo(removeBackground: BackgroundRemoval())))
        #expect(throws: ConversionError.self) {
            _ = try ImageConverter.convert(PhotoFixture.encode(PhotoFixture.solid(0.5, 0.5, 0.5, width: 300, height: 300)), request: request)
        }
    }
}
