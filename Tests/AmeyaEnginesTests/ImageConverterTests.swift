import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AmeyaEngines

@Suite("Image conversion")
struct ImageConverterTests {
    static let writableImageTargets = FileFormat.allCases.filter {
        $0.family == .image && FileFormat.systemWritable().contains($0)
    }

    @Test("A transparent PNG converts to every writable format", arguments: writableImageTargets)
    func pngToEveryTarget(target: FileFormat) throws {
        let source = try Fixtures.encode([Fixtures.halfTransparent()], as: .png)
        let (output, result) = try ImageConverter.convert(source, request: ConversionRequest(target: target))

        #expect(FileFormat.detect(header: output.prefix(512), fileExtension: target.preferredExtension) == target)
        #expect(result.outputBytes == output.count)
        let decoded = try #require(Fixtures.decode(output))
        if target.isIcon {
            // 64×48 becomes square icons at every standard size that fits (ICNS has no 64 px slot).
            #expect(decoded.allSatisfy { $0.width == $0.height })
            #expect(decoded.map(\.width).max() == (target == .icns ? 32 : 64), "\(decoded.map(\.width))")
            #expect(result.notes == [.madeSquareIcon])
            return
        }
        #expect(decoded.count == 1)
        #expect(decoded[0].width == 64 && decoded[0].height == 48)
        if !target.supportsAlpha {
            #expect(result.notes.contains(.transparencyFilledWhite))
        }
    }

    @Test func transparencyBecomesWhiteNotBlack() throws {
        let source = try Fixtures.encode([Fixtures.halfTransparent()], as: .png)
        let (output, _) = try ImageConverter.convert(source, request: ConversionRequest(target: .jpeg))
        let image = try #require(Fixtures.decode(output)?.first)
        let (red, green, blue) = try #require(Fixtures.pixel(of: image, x: 5, y: 24))
        #expect(red > 240 && green > 240 && blue > 240)
    }

    @Test func animationSurvivesWhereSupported() throws {
        let gif = try Fixtures.encode(Fixtures.frames(3), as: .gif, delay: 0.2)

        let (png, pngResult) = try ImageConverter.convert(gif, request: ConversionRequest(target: .png))
        #expect(Fixtures.decode(png)?.count == 3)
        #expect(pngResult.notes.isEmpty)

        let (jpeg, jpegResult) = try ImageConverter.convert(gif, request: ConversionRequest(target: .jpeg))
        #expect(Fixtures.decode(jpeg)?.count == 1)
        #expect(jpegResult.notes.contains(.onlyFirstFrameKept))

        let (pdf, pdfResult) = try ImageConverter.convert(gif, request: ConversionRequest(target: .pdf))
        #expect(Fixtures.pageCount(pdf) == 3)
        #expect(pdfResult.notes == [.animationBecamePages])
    }

    @Test func frameDelaysAreKept() throws {
        let gif = try Fixtures.encode(Fixtures.frames(2), as: .gif, delay: 0.25)
        let (png, _) = try ImageConverter.convert(gif, request: ConversionRequest(target: .png))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pngProperties = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let delay = try #require(pngProperties?[kCGImagePropertyAPNGDelayTime] as? Double)
        #expect(abs(delay - 0.25) < 0.02)
    }

    @Test func multiPageTIFFBecomesMultiPagePDFAndBack() throws {
        let tiff = try Fixtures.encode(Fixtures.frames(4), as: .tiff)
        let (pdf, _) = try ImageConverter.convert(tiff, request: ConversionRequest(target: .pdf))
        #expect(Fixtures.pageCount(pdf) == 4)

        let (backToTIFF, _) = try ImageConverter.convert(pdf, request: ConversionRequest(target: .tiff))
        #expect(Fixtures.decode(backToTIFF)?.count == 4)

        let (png, result) = try ImageConverter.convert(pdf, request: ConversionRequest(target: .png))
        #expect(Fixtures.decode(png)?.count == 1)
        #expect(result.notes.contains(.onlyFirstPageKept))
    }

    @Test func pdfPagesRenderAtTwiceTheirPointSize() throws {
        let tiff = try Fixtures.encode([Fixtures.halfTransparent()], as: .tiff)
        let (pdf, _) = try ImageConverter.convert(tiff, request: ConversionRequest(target: .pdf))
        let (png, _) = try ImageConverter.convert(pdf, request: ConversionRequest(target: .png))
        let image = try #require(Fixtures.decode(png)?.first)
        #expect(image.width == 128 && image.height == 96)
    }

    @Test func refusesImagesOverThePixelLimit() throws {
        let source = try Fixtures.encode([Fixtures.halfTransparent()], as: .png)
        let request = ConversionRequest(target: .jpeg, options: ConversionOptions(maxPixels: 1_000))
        #expect(throws: ConversionError.tooLarge(pixels: 64 * 48, limit: 1_000)) {
            try ImageConverter.convert(source, request: request)
        }
    }

    @Test func rejectsGarbage() {
        #expect(throws: ConversionError.unreadable) {
            try ImageConverter.convert(Data("not an image at all".utf8), request: ConversionRequest(target: .png))
        }
        var truncated = (try? Fixtures.encode([Fixtures.halfTransparent()], as: .png)) ?? Data()
        truncated = truncated.prefix(40)
        #expect(throws: (any Error).self) {
            try ImageConverter.convert(truncated, request: ConversionRequest(target: .jpeg))
        }
    }

    @Test func exifOrientationIsAppliedToPixels() throws {
        // A 64×48 image tagged "rotate 90° clockwise" must come out 48×64 and untagged.
        let tagged = try Fixtures.encode([Fixtures.halfTransparent()], as: .jpeg, orientation: 6)
        let (png, _) = try ImageConverter.convert(tagged, request: ConversionRequest(target: .png))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 48 && image.height == 64)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect((properties?[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }
}
