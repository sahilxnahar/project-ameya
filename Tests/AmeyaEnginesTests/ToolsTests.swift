import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import AmeyaEngines

/// PDFs whose page N is N×10 points wide, so order can be read back from page sizes.
enum PDFFixtures {
    static func numbered(_ count: Int) -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        let context = CGContext(consumer: consumer, mediaBox: nil, nil)!
        for number in 1...count {
            var box = CGRect(x: 0, y: 0, width: CGFloat(number * 10), height: 100)
            context.beginPage(mediaBox: &box)
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 5, height: 5))
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }

    static func widths(_ url: URL) -> [Int] {
        guard let document = PDFDocument(url: url) else { return [] }
        return (0..<document.pageCount).map { Int(document.page(at: $0)!.bounds(for: .mediaBox).width) }
    }
}

@Suite("PDF tools")
@MainActor
struct PDFToolsTests {
    let scratch: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-pdftools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func run(_ action: AmeyaCore.PDFAction, _ inputs: [URL], formats: [FileFormat]? = nil) throws -> (outputs: [URL], result: ConversionResult) {
        let request = ConversionRequest(source: .pdf, target: .pdf, options: ConversionOptions(pdf: action),
                                        inputs: formats ?? (inputs.count > 1 ? inputs.map { _ in .pdf } : nil))
        let work = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return try PDFTools.run(action, inputs: inputs, request: request, scratch: work) { _ in }
    }

    @Test func mergesPDFsAndImagesInOrder() throws {
        let a = try file("a.pdf", PDFFixtures.numbered(2))
        let png = try file("c.png", Fixtures.encode([Fixtures.frames(1)[0]], as: .png))
        let b = try file("b.pdf", PDFFixtures.numbered(1))
        let (outputs, result) = try run(.merge, [a, png, b], formats: [.pdf, .png, .pdf])
        #expect(outputs.count == 1)
        #expect(result.outputNames == nil)
        #expect(result.frames == 4)
        // 64×48 pixels at 72 dpi becomes a 64-point-wide page.
        #expect(PDFFixtures.widths(outputs[0]) == [10, 20, 64, 10])
    }

    @Test func splitsEveryPage() throws {
        let pdf = try file("three.pdf", PDFFixtures.numbered(3))
        let (outputs, result) = try run(.splitEveryPage, [pdf])
        #expect(result.outputNames == ["Page 001.pdf", "Page 002.pdf", "Page 003.pdf"])
        #expect(outputs.map(PDFFixtures.widths) == [[10], [20], [30]])
    }

    @Test func splitsRanges() throws {
        let pdf = try file("five.pdf", PDFFixtures.numbered(5))
        let (outputs, result) = try run(.splitRanges([1...2, 3...3, 4...5]), [pdf])
        #expect(result.outputNames == ["Pages 1-2.pdf", "Page 3.pdf", "Pages 4-5.pdf"])
        #expect(outputs.map(PDFFixtures.widths) == [[10, 20], [30], [40, 50]])
        #expect(throws: ConversionError.self) { try run(.splitRanges([4...9]), [pdf]) }
        #expect(throws: ConversionError.self) { try run(.splitRanges([1...2, 1...2]), [pdf]) }
    }

    @Test func rotatesAllOrSomePages() throws {
        let pdf = try file("rot.pdf", PDFFixtures.numbered(3))
        let all = try run(.rotate(degrees: 90, pages: nil), [pdf]).outputs[0]
        #expect(rotations(all) == [90, 90, 90])
        let some = try run(.rotate(degrees: -90, pages: [2]), [pdf]).outputs[0]
        #expect(rotations(some) == [0, 270, 0])
        #expect(throws: ConversionError.self) { try run(.rotate(degrees: 45, pages: nil), [pdf]) }
    }

    @Test func deletesAndReordersPages() throws {
        let pdf = try file("four.pdf", PDFFixtures.numbered(4))
        #expect(PDFFixtures.widths(try run(.deletePages([2, 4]), [pdf]).outputs[0]) == [10, 30])
        #expect(PDFFixtures.widths(try run(.reorder([4, 1, 3, 2]), [pdf]).outputs[0]) == [40, 10, 30, 20])
        #expect(throws: ConversionError.self) { try run(.deletePages([1, 2, 3, 4]), [pdf]) }
        #expect(throws: ConversionError.self) { try run(.reorder([0]), [pdf]) }
    }

    @Test func refusesLockedPDFsAndUnbuiltTools() throws {
        let document = PDFDocument(data: PDFFixtures.numbered(1))!
        let locked = scratch.appendingPathComponent("locked.pdf")
        #expect(document.write(to: locked, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
        #expect(throws: ConversionError.lockedPDF) { try run(.splitEveryPage, [locked]) }

        let pdf = try file("plain.pdf", PDFFixtures.numbered(1))
        #expect(throws: ConversionError.notAvailableYet("Making PDFs smaller")) { try run(.compress(quality: 0.5), [pdf]) }
        #expect(throws: ConversionError.self) { try run(.ocr(languages: nil), [pdf]) }
    }

    private func rotations(_ url: URL) -> [Int] {
        guard let document = PDFDocument(url: url) else { return [] }
        return (0..<document.pageCount).map { document.page(at: $0)!.rotation }
    }
}

@Suite("Image edits")
struct ImageEditorTests {
    /// 64×48: left half red, right half blue.
    private static func twoTone() -> CGImage {
        let context = Fixtures.context()
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 48))
        return context.makeImage()!
    }

    private func convert(_ data: Data, from source: FileFormat, to target: FileFormat, _ edits: ImageEdits) throws -> (CGImage, ConversionResult, Data) {
        let request = ConversionRequest(source: source, target: target, options: ConversionOptions(image: edits))
        let (output, result) = try ImageConverter.convert(data, request: request)
        return (try #require(Fixtures.decode(output)?.first), result, output)
    }

    private var png: Data { get throws { try Fixtures.encode([Self.twoTone()], as: .png) } }

    // Colour management shifts values slightly, so compare the dominant channel.
    private func isRed(_ image: CGImage, _ x: Int, _ y: Int) -> Bool {
        guard let (r, _, b) = Fixtures.pixel(of: image, x: x, y: y) else { return false }
        return r > 200 && b < 80
    }

    private func isBlue(_ image: CGImage, _ x: Int, _ y: Int) -> Bool {
        guard let (r, _, b) = Fixtures.pixel(of: image, x: x, y: y) else { return false }
        return b > 200 && r < 80
    }

    @Test func cropsTheUprightImage() throws {
        // Right half, top quarter.
        let (image, _, _) = try convert(try png, from: .png, to: .png, ImageEdits(crop: UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.25)))
        #expect(image.width == 32 && image.height == 12)
        #expect(isBlue(image, 5, 5))
    }

    @Test func rotatesClockwiseAndFlips() throws {
        let (right, _, _) = try convert(try png, from: .png, to: .png, ImageEdits(rotation: 90))
        #expect(right.width == 48 && right.height == 64)
        // Red was on the left; after a clockwise turn it is on top.
        #expect(isRed(right, 24, 5))
        #expect(isBlue(right, 24, 58))

        let (left, _, _) = try convert(try png, from: .png, to: .png, ImageEdits(rotation: 270))
        #expect(isRed(left, 24, 58))

        let (mirrored, _, _) = try convert(try png, from: .png, to: .png, ImageEdits(flipHorizontal: true))
        #expect(mirrored.width == 64 && mirrored.height == 48)
        #expect(isBlue(mirrored, 5, 5))

        #expect(throws: ConversionError.self) { try convert(try png, from: .png, to: .png, ImageEdits(rotation: 45)) }
    }

    @Test func resizesWithoutEnlarging() throws {
        let (small, result, _) = try convert(try png, from: .png, to: .png, ImageEdits(maxPixelSize: 32))
        #expect(small.width == 32 && small.height == 24)
        #expect(result.notes.contains(.resized))
        let (same, unchanged, _) = try convert(try png, from: .png, to: .png, ImageEdits(maxPixelSize: 4000))
        #expect(same.width == 64 && same.height == 48)
        #expect(!unchanged.notes.contains(.resized))
    }

    @Test func removesLocationOrAllMetadata() throws {
        let jpeg = try photoWithLocation()
        let (_, kept, keptData) = try convert(jpeg, from: .jpeg, to: .jpeg, ImageEdits(rotation: 180))
        #expect(properties(keptData)[kCGImagePropertyGPSDictionary] != nil)
        #expect(!kept.notes.contains(.locationRemoved))

        let (_, noGPS, noGPSData) = try convert(jpeg, from: .jpeg, to: .jpeg, ImageEdits(metadata: .removeLocation))
        #expect(properties(noGPSData)[kCGImagePropertyGPSDictionary] == nil)
        #expect((properties(noGPSData)[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String == "Acme")
        #expect(noGPS.notes.contains(.locationRemoved))

        let (_, none, noneData) = try convert(jpeg, from: .jpeg, to: .jpeg, ImageEdits(metadata: .removeAll))
        let stripped = properties(noneData)
        #expect(stripped[kCGImagePropertyGPSDictionary] == nil)
        #expect((stripped[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] == nil)
        #expect((stripped[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel] == nil)
        #expect(none.notes.contains(.metadataRemoved))
    }

    @Test func meetsAByteTargetForJPEG() throws {
        let noisy = try Fixtures.encode([Self.noise(width: 800, height: 600)], as: .png)
        let target = 40_000
        let (_, result, data) = try convert(noisy, from: .png, to: .jpeg, ImageEdits(targetBytes: target))
        #expect(data.count <= target)
        #expect(!result.notes.contains(.targetSizeNotReached))

        // An impossible target returns the smallest attempt and says so.
        let (_, tiny, _) = try convert(noisy, from: .png, to: .jpeg, ImageEdits(targetBytes: 100))
        #expect(tiny.notes.contains(.targetSizeNotReached))

        // Lossless targets only shrink.
        let (shrunk, lossless, pngData) = try convert(noisy, from: .png, to: .png, ImageEdits(targetBytes: 600_000))
        #expect(pngData.count <= 600_000 || lossless.notes.contains(.targetSizeNotReached))
        #expect(shrunk.width < 800)
    }

    private func photoWithLocation() throws -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, FileFormat.jpeg.typeIdentifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, Self.twoTone(), [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Acme"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Test Lens"],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func properties(_ data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    /// Random pixels compress badly, which makes byte targets meaningful.
    static func noise(width: Int, height: Int) -> CGImage {
        let context = Fixtures.context(width: width, height: height)
        var generator = SystemRandomNumberGenerator()
        let pixels = context.data!.bindMemory(to: UInt32.self, capacity: width * height)
        let stride = context.bytesPerRow / 4
        for y in 0..<height {
            for x in 0..<width { pixels[y * stride + x] = UInt32.random(in: 0...UInt32.max, using: &generator) | 0xFF00_0000 }
        }
        return context.makeImage()!
    }
}
