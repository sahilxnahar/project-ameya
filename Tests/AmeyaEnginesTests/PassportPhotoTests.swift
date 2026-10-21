import AmeyaCore
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing
import Vision
@testable import AmeyaEngines

/// A face Vision recognises without any photo on disk: the "person, medium skin tone" emoji
/// (🧑🏽), drawn large on grey. Other emoji (🙂, 👩) are not detected as faces.
enum FaceFixture {
    static func image(canvas: (Int, Int) = (1200, 1500), pointSize: CGFloat = 600, faces: Int = 1,
                      rotationDegrees: Double = 0) -> CGImage {
        let context = CGContext(data: nil, width: canvas.0, height: canvas.1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: canvas.0, height: canvas.1))
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, pointSize, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "\u{1F9D1}\u{1F3FD}", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        let glyphWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        for index in 0..<faces {
            let centreX = Double(canvas.0) * (Double(index) + 0.5) / Double(faces)
            context.saveGState()
            context.translateBy(x: centreX, y: Double(canvas.1) * 0.5)
            context.rotate(by: -rotationDegrees * .pi / 180) // clockwise on screen
            context.textPosition = CGPoint(x: -glyphWidth / 2, y: -Double(pointSize) * 0.4)
            CTLineDraw(line, context)
            context.restoreGState()
        }
        return context.makeImage()!
    }

    static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func faceFound(_ image: CGImage) -> Bool { (try? PassportPhoto.analyse(image)) != nil }
}

@Suite("Passport photo geometry")
struct PassportGeometryTests {
    let us = PassportSpec.presets.first { $0.id == "us" }!
    let uk = PassportSpec.presets.first { $0.id == "uk" }!

    @Test("Millimetres to pixels at 300 dpi")
    func millimetres() {
        #expect(PassportGeometry.pixels(mm: 35, dpi: 300) == 413)
        #expect(PassportGeometry.pixels(mm: 45, dpi: 300) == 531)
        #expect(PassportGeometry.pixels(mm: 50.8, dpi: 300) == 600)
        #expect(PassportGeometry.pixels(mm: 152.4, dpi: 300) == 1800)
        #expect(us.digitalPixelSize == (600, 600))
        #expect(PassportSpec.presets.first { $0.id == "au" }!.digitalPixelSize == (413, 531))
    }

    @Test("Head height and eye line land on the US rules")
    func usPlacement() {
        let face = PassportGeometry.Face(eyeX: 1000, eyeY: 800, eyeToChin: 200)
        let placement = PassportGeometry.placement(for: face, spec: us, outputWidth: 600, outputHeight: 600)
        // Head 30.1625 mm (middle of 1–1⅜ in) = 356.25 px; the estimated head is 200 / 0.48 px.
        #expect(abs(placement.scale - 0.855) < 1e-9)
        #expect(abs(placement.sourceRect.width - 600 / 0.855) < 1e-9)
        #expect(abs(placement.sourceRect.x - (1000 - 300 / 0.855)) < 1e-9)
        // Eyes 31.75 mm from the bottom = 375 px up, so 225 px from the top.
        #expect(abs(placement.sourceRect.y - (800 - 225 / 0.855)) < 1e-9)
        let measured = PassportGeometry.measured(face, placement, spec: us, outputHeight: 600)
        #expect(abs(measured.headMM - 30.1625) < 1e-9)
        #expect(abs(measured.eyeFromBottomMM - 31.75) < 1e-9)
        #expect(measured.crownMarginMM > 0)
        #expect(placement.sourceRect.isInside(width: 2000, height: 2000))
    }

    @Test("Without an eye rule the head sits slightly above centre")
    func ukPlacement() {
        let face = PassportGeometry.Face(eyeX: 500, eyeY: 600, eyeToChin: 240)
        let placement = PassportGeometry.placement(for: face, spec: uk, outputWidth: 600, outputHeight: 750)
        let measured = PassportGeometry.measured(face, placement, spec: uk, outputHeight: 750)
        #expect(abs(measured.headMM - 31.5) < 1e-9)
        // Free height 45 − 31.5 = 13.5 mm; 42 % of it above the head.
        #expect(abs(measured.crownMarginMM - 5.67) < 1e-9)
        #expect(abs(placement.sourceRect.width / placement.sourceRect.height - 0.8) < 1e-9)
    }

    @Test("A face near the edge needs filling")
    func outOfBounds() {
        let face = PassportGeometry.Face(eyeX: 100, eyeY: 120, eyeToChin: 150)
        let placement = PassportGeometry.placement(for: face, spec: uk, outputWidth: 600, outputHeight: 750)
        #expect(!placement.sourceRect.isInside(width: 1000, height: 1000))
        #expect(placement.sourceRect.x < 0 && placement.sourceRect.y < 0)
    }

    @Test("Print sheet tiling", arguments: [
        (35.0, 45.0, 8, true, 2.0), (50.8, 50.8, 6, false, 0), (50, 70, 4, false, 0),
        (33, 48, 9, false, 0), (43, 55, 4, false, 2),
    ])
    func tiling(width: Double, height: Double, count: Int, landscape: Bool, gap: Double) {
        let layout = PassportGeometry.sheetLayout(photoWidthMM: width, photoHeightMM: height)
        #expect(layout.count == count)
        #expect(layout.landscape == landscape)
        #expect(layout.gapMM == gap)
        let frames = PassportGeometry.sheetFrames(layout, photoWidthMM: width, photoHeightMM: height, dpi: 300)
        let sheetW = Double(PassportGeometry.pixels(mm: layout.sheetWidthMM, dpi: 300))
        let sheetH = Double(PassportGeometry.pixels(mm: layout.sheetHeightMM, dpi: 300))
        #expect(frames.count == count)
        #expect(frames.allSatisfy { $0.isInside(width: sheetW, height: sheetH, tolerance: 0) })
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] {
                let apart = a.x + a.width <= b.x + 1 || b.x + b.width <= a.x + 1
                    || a.y + a.height <= b.y + 1 || b.y + b.height <= a.y + 1
                #expect(apart)
            }
        }
    }

    @Test("Preset table is sane")
    func presets() {
        let presets = PassportSpec.presets
        #expect(Set(presets.map(\.id)).count == presets.count)
        #expect(!presets.contains { $0.id == PassportSpec.customID })
        for spec in presets {
            #expect(!spec.name.isEmpty)
            #expect(spec.headHeightMM.lowerBound < spec.headHeightMM.upperBound, "\(spec.id)")
            #expect(spec.headHeightMM.upperBound < spec.heightMM, "\(spec.id)")
            #expect(spec.headHeightMM.lowerBound >= spec.heightMM * 0.4, "\(spec.id)")
            if let eye = spec.eyeLineFromBottomMM { #expect(eye.upperBound < spec.heightMM) }
            let digital = spec.digitalPixelSize
            let ratio = Double(digital.width) / Double(digital.height)
            #expect(abs(ratio / (spec.widthMM / spec.heightMM) - 1) < 0.1, "\(spec.id) digital aspect")
            #expect(digital.height >= 400, "\(spec.id)")
            if let max = spec.maxBytes, let min = spec.minBytes { #expect(min < max) }
            #expect(PassportGeometry.sheetLayout(photoWidthMM: spec.widthMM, photoHeightMM: spec.heightMM).count >= 2)
        }
        #expect(PassportSpec.search("india").map(\.id) == ["in-passport", "in-visa", "in-oci"])
        #expect(PassportSpec.search("OCI").map(\.id) == ["in-oci"])
        #expect(PassportSpec.search("  ").count == presets.count)
        #expect(PassportSpec.preset(forRegion: "IN")?.id == "in-passport")
        #expect(PassportSpec.preset(forRegion: "gb")?.id == "uk")
        #expect(PassportSpec.preset(forRegion: "ZZ") == nil)
        #expect(us.sizeText == "2 × 2 in")
        #expect(uk.sizeText == "35 × 45 mm")
        let custom = PassportSpec.custom(widthMM: 40, heightMM: 50)
        #expect(custom.headHeightMM == 35...40)
    }
}

@Suite("Passport photo engine")
@MainActor
struct PassportPhotoEngineTests {
    let scratch: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-passport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    func run(_ image: CGImage, _ options: PassportPhotoOptions) throws -> (outputs: [URL], result: ConversionResult) {
        let input = scratch.appendingPathComponent("input.png")
        try FaceFixture.png(image).write(to: input)
        var conversion = ConversionOptions()
        conversion.passport = options
        return try PassportPhoto.run(options, input: input, request: ConversionRequest(source: .png, target: .jpeg, options: conversion),
                                     scratch: scratch) { _ in }
    }

    func spec(_ id: String) -> PassportSpec { PassportSpec.presets.first { $0.id == id }! }

    @Test("No face gives a friendly message")
    func noFace() throws {
        let plain = Fixtures.context(width: 400, height: 500).makeImage()!
        #expect(throws: ConversionError.needsDifferentPhoto(
            "No face was found. Use a clear, well-lit photo of one person looking at the camera.")) {
            try run(plain, PassportPhotoOptions(spec: spec("uk")))
        }
    }

    @Test("A detected face becomes a digital photo of the right size, without metadata")
    func digital() throws {
        let image = FaceFixture.image()
        guard FaceFixture.faceFound(image) else {
            print("Vision does not see the emoji face on this macOS; the face path is covered by the geometry tests")
            return
        }
        let (outputs, result) = try run(image, PassportPhotoOptions(spec: spec("uk")))
        #expect(outputs.count == 1 && result.outputNames == nil)
        let data = try Data(contentsOf: outputs[0])
        #expect(FileFormat.sniff(data.prefix(32)) == .jpeg)
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 600)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 750)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect((properties[kCGImagePropertyDPIHeight] as? Double).map { abs($0 - 423.33) < 0.1 } == true)
        #expect(data.count <= 10_000_000)
        #expect(result.notes.contains(.passportBackgroundReplaced) || result.notes.contains(.passportBackgroundKept))
    }

    @Test("Size limits are respected")
    func sizeLimit() throws {
        let image = FaceFixture.image()
        guard FaceFixture.faceFound(image) else { return }
        let china = spec("cn-visa")
        let (outputs, result) = try run(image, PassportPhotoOptions(spec: china, replaceBackground: false))
        let data = try Data(contentsOf: outputs[0])
        #expect(data.count <= 120_000)
        #expect(!result.notes.contains(.passportBackgroundReplaced))
    }

    @Test("A tilted head is levelled")
    func tilted() throws {
        // The emoji's own eyes aren't perfectly level, so compare against the upright drawing.
        guard let upright = try? PassportPhoto.analyse(FaceFixture.image()),
              let tilted = try? PassportPhoto.analyse(FaceFixture.image(rotationDegrees: 12)) else { return }
        let turned = (tilted.roll - upright.roll) * 180 / .pi
        #expect(abs(turned - 12) < 3, "measured \(turned)°")
        #expect(tilted.notes.contains(.passportHeadStraightened))
        // Head size is measured along the face, so tilting barely changes it.
        #expect(abs(tilted.face.eyeToChin / upright.face.eyeToChin - 1) < 0.1)
    }

    @Test("Two faces are refused")
    func twoFaces() throws {
        let image = FaceFixture.image(canvas: (2000, 1200), pointSize: 500, faces: 2)
        let count = (try? VNCount.faces(image)) ?? 0
        guard count == 2 else { return }
        #expect(throws: ConversionError.needsDifferentPhoto("This photo shows 2 faces. Use a photo of just one person.")) {
            try PassportPhoto.analyse(image)
        }
    }

    @Test("Print sheet as JPEG and PDF")
    func printSheet() throws {
        let image = FaceFixture.image()
        guard FaceFixture.faceFound(image) else { return }
        let (outputs, result) = try run(image, PassportPhotoOptions(spec: spec("in-passport"), printSheet: true))
        #expect(result.outputNames == ["Photo (India passport).jpg", "Print sheet 4x6 in (India passport).jpg",
                                       "Print sheet 4x6 in (India passport).pdf"])
        let sheet = CGImageSourceCreateWithURL(outputs[1] as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        #expect(sheet?.width == 1800 && sheet?.height == 1200)
        let page = PDFDocument(url: outputs[2])?.page(at: 0)?.bounds(for: .mediaBox)
        #expect(page.map { abs($0.width - 432) < 0.01 && abs($0.height - 288) < 0.01 } == true)
        #expect(result.notes.contains(.passportCheckRules))
    }
}

/// Raw Vision face count, to tell "Vision missed a face" apart from the engine's own rules.
enum VNCount {
    static func faces(_ image: CGImage) throws -> Int {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results?.count ?? 0
    }
}
