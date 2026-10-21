import AmeyaCore
import CoreGraphics
import Foundation
import Testing
@testable import AmeyaEngines

@Suite("SVG rendering")
struct SVGTests {
    /// 200×100 drawing (viewBox 20×10, scaled ×10): left half red, right half empty.
    static let halfRed = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- test drawing -->
    <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 20 10">
      <rect x="0" y="0" width="10" height="10" fill="#ff0000"/>
    </svg>
    """#

    static func convert(_ svg: String, to target: FileFormat, options: ConversionOptions = ConversionOptions()) throws -> (Data, ConversionResult) {
        try convert(Data(svg.utf8), to: target, options: options)
    }

    static func convert(_ svg: Data, to target: FileFormat, options: ConversionOptions = ConversionOptions()) throws -> (Data, ConversionResult) {
        try ImageConverter.convert(svg, request: ConversionRequest(source: .svg, target: target, options: options))
    }

    /// RGBA of one pixel (origin top-left), not premultiplied for opaque pixels.
    static func rgba(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 4)
        buffer.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return buffer
    }

    static func gzip(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data // raw DEFLATE
        return Data([0x1F, 0x8B, 0x08, 0x08, 0, 0, 0, 0, 0, 0x03]) + Data("t.svg".utf8) + Data([0])
            + deflated + Data(repeating: 0, count: 8)
    }

    // MARK: Raster output

    @Test func viewBoxShapesBecomeTransparentPNG() throws {
        let (png, result) = try Self.convert(Self.halfRed, to: .png)
        #expect(FileFormat.sniff(png) == .png)
        let image = try #require(Fixtures.decode(png)?.first)
        #expect(image.width == 200 && image.height == 100)
        #expect(Self.rgba(image, x: 50, y: 50) == [255, 0, 0, 255])
        #expect(Self.rgba(image, x: 150, y: 50)[3] == 0, "outside the shape stays transparent")
        #expect(result.notes.isEmpty)
    }

    @Test func everyWritableImageFormatWorks() throws {
        let targets = ConversionMatrix(writable: FileFormat.systemWritable()).targets(for: .svg).filter { $0.family == .image }
        #expect(targets.count > 5)
        for target in targets {
            let (output, _) = try Self.convert(Self.halfRed, to: target)
            #expect(FileFormat.detect(header: output.prefix(512), fileExtension: target.preferredExtension) == target, "\(target)")
        }
    }

    @Test func jpegGetsAWhiteBackground() throws {
        let (jpeg, result) = try Self.convert(Self.halfRed, to: .jpeg)
        let image = try #require(Fixtures.decode(jpeg)?.first)
        let (red, green, blue) = try #require(Fixtures.pixel(of: image, x: 150, y: 50))
        #expect(red > 240 && green > 240 && blue > 240)
        #expect(result.notes == [.transparencyFilledWhite])
    }

    @Test func noIntrinsicSizeUses1024OnTheLongSide() throws {
        let viewBoxOnly = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 200"><circle cx="200" cy="100" r="50" fill="blue"/></svg>"#
        let image = try #require(Fixtures.decode(try Self.convert(viewBoxOnly, to: .png).0)?.first)
        #expect(image.width == 1024 && image.height == 512)
        #expect(Self.rgba(image, x: 512, y: 256) == [0, 0, 255, 255])

        let percent = #"<svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%" viewBox="0 0 30 60"><rect width="30" height="60" fill="lime"/></svg>"#
        let tall = try #require(Fixtures.decode(try Self.convert(percent, to: .png).0)?.first)
        #expect(tall.width == 512 && tall.height == 1024)

        let bare = #"<svg xmlns="http://www.w3.org/2000/svg"><rect width="50" height="50" fill="lime"/></svg>"#
        let square = try #require(Fixtures.decode(try Self.convert(bare, to: .png).0)?.first)
        #expect(max(square.width, square.height) == 1024)
    }

    @Test func absoluteUnitsAreHonoured() throws {
        let inches = #"<svg xmlns="http://www.w3.org/2000/svg" width="2in" height="1in"><rect width="10" height="10"/></svg>"#
        let image = try #require(Fixtures.decode(try Self.convert(inches, to: .png).0)?.first)
        #expect(image.width == 144 && image.height == 72)
        // `stroke-width` on the root is not mistaken for `width`.
        let stroked = #"<svg xmlns="http://www.w3.org/2000/svg" stroke-width="3" viewBox="0 0 10 5"><rect width="10" height="5"/></svg>"#
        let wide = try #require(Fixtures.decode(try Self.convert(stroked, to: .png).0)?.first)
        #expect(wide.width == 1024 && wide.height == 512)
    }

    @Test func targetSizeOption() throws {
        var options = ConversionOptions()
        options.rasterLongSide = 300
        let image = try #require(Fixtures.decode(try Self.convert(Self.halfRed, to: .png, options: options).0)?.first)
        #expect(image.width == 300 && image.height == 150)
        #expect(Self.rgba(image, x: 75, y: 75) == [255, 0, 0, 255])
    }

    @Test func hugeSizesAreScaledDownToTheLimits() throws {
        var options = ConversionOptions()
        options.maxPixels = 2_000_000
        let huge = #"<svg xmlns="http://www.w3.org/2000/svg" width="100000" height="50000"><rect width="10" height="10"/></svg>"#
        let image = try #require(Fixtures.decode(try Self.convert(huge, to: .png, options: options).0)?.first)
        #expect(image.width == 2000 && image.height == 1000)

        let document = try SVGRenderer.load(Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="40000" height="10"/>"#.utf8))
        let (width, height) = try SVGRenderer.pixelSize(for: document, options: ConversionOptions())
        #expect(width == SVGRenderer.maxSide && height == 4)
    }

    // MARK: Vector PDF

    @Test func pdfStaysVector() throws {
        let (pdf, result) = try Self.convert(Self.halfRed, to: .pdf)
        #expect(FileFormat.sniff(pdf) == .pdf)
        #expect(result.frames == 1)
        let document = try #require(CGPDFDocument(CGDataProvider(data: pdf as CFData)!))
        #expect(document.numberOfPages == 1)
        let page = try #require(document.page(at: 1))
        #expect(page.getBoxRect(.mediaBox).size == CGSize(width: 200, height: 100))
        #expect(!Self.containsImage(page.dictionary), "no embedded bitmaps")
        #expect(pdf.count < 20_000, "\(pdf.count) bytes")
    }

    @Test func pdfKeepsTextAsText() throws {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="300" height="80"><text x="10" y="50" font-family="Helvetica" font-size="30">Hello Ameya</text></svg>"#
        let (pdf, _) = try Self.convert(svg, to: .pdf)
        let page = try #require(CGPDFDocument(CGDataProvider(data: pdf as CFData)!)?.page(at: 1))
        #expect(!Self.containsImage(page.dictionary))
        #expect(String(decoding: pdf, as: UTF8.self).contains("/Font"))
    }

    /// True when a page's resources (or nested forms) contain an image XObject.
    static func containsImage(_ dictionary: CGPDFDictionaryRef?) -> Bool {
        guard let dictionary else { return false }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return false }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return false }
        var found = false
        CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let streamDictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype), let subtype {
                if String(cString: subtype) == "Image" { found = true }
                if String(cString: subtype) == "Form", containsImage(streamDictionary) { found = true }
            }
            return !found
        }, nil)
        return found
    }

    // MARK: Input handling

    @Test func svgzInput() throws {
        let svgz = try Self.gzip(Data(Self.halfRed.utf8))
        #expect(FileFormat.detect(header: svgz.prefix(512), fileExtension: "svgz") == .svg)
        let image = try #require(Fixtures.decode(try Self.convert(svgz, to: .png).0)?.first)
        #expect(image.width == 200 && image.height == 100)
        #expect(Self.rgba(image, x: 50, y: 50) == [255, 0, 0, 255])
        let (pdf, _) = try Self.convert(svgz, to: .pdf)
        #expect(Fixtures.pageCount(pdf) == 1)
    }

    @Test func gzipBombIsRefused() throws {
        let bomb = try Self.gzip(Data("<svg xmlns=\"http://www.w3.org/2000/svg\">".utf8) + Data(repeating: 0x20, count: 30 << 20))
        #expect(bomb.count < 1 << 20)
        #expect(throws: ConversionError.self) { try Self.convert(bomb, to: .png) }
    }

    @Test func detectedWithoutASourceHint() throws {
        let (png, _) = try ImageConverter.convert(Data(Self.halfRed.utf8), request: ConversionRequest(target: .png))
        #expect(Fixtures.decode(png)?.first?.width == 200)
    }

    @Test("Malformed or non-SVG input is rejected", arguments: [
        #"<svg xmlns="http://www.w3.org/2000/svg" width="200" <rect"#,
        "<html><body>not an svg</body></html>",
        "",
        #"<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;">]><svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><text>&b;</text></svg>"#,
    ])
    func rejectsBadInput(svg: String) {
        #expect(throws: ConversionError.self) { try Self.convert(svg, to: .png) }
        #expect(throws: ConversionError.self) { try Self.convert(svg, to: .pdf) }
    }

    @Test func externalReferencesAreDroppedWithoutWaiting() throws {
        // 10.255.255.1 is unroutable: a renderer that fetched it would hang until a network timeout.
        let svg = #"""
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="100" height="100">
          <style>@import url("http://10.255.255.1/a.css"); .x { fill: url(http://10.255.255.1/p.svg#g) }</style>
          <image href="http://10.255.255.1/x.png" width="100" height="50"/>
          <image xlink:href='file:///System/Library/CoreServices/DefaultDesktop.heic' y="50" width="100" height="50"/>
          <rect class="x" width="10" height="10"/>
        </svg>
        """#
        let start = ContinuousClock.now
        let (png, result) = try Self.convert(svg, to: .png)
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(result.notes == [.externalResourcesSkipped])
        let image = try #require(Fixtures.decode(png)?.first)
        #expect(Self.rgba(image, x: 50, y: 25)[3] == 0, "the remote image is not drawn")
        #expect(Self.rgba(image, x: 50, y: 75)[3] == 0, "the local file is not read")
    }

    @Test func embeddedDataAndFragmentsAreKept() throws {
        // A 1×1 red PNG as a data: URI, and a <use> of a local definition.
        let red = try Fixtures.encode([Self.solid(red: 1)], as: .png).base64EncodedString()
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="100" height="100">
          <defs><rect id="b" width="50" height="100" fill="#0000ff"/></defs>
          <use xlink:href="#b"/>
          <image href="data:image/png;base64,\(red)" x="50" width="50" height="100" preserveAspectRatio="none"/>
        </svg>
        """
        let (png, result) = try Self.convert(svg, to: .png)
        #expect(result.notes.isEmpty)
        let image = try #require(Fixtures.decode(png)?.first)
        #expect(Self.rgba(image, x: 25, y: 50) == [0, 0, 255, 255])
        #expect(Self.rgba(image, x: 75, y: 50)[0] > 200 && Self.rgba(image, x: 75, y: 50)[3] == 255)
    }

    static func solid(red: CGFloat) -> CGImage {
        let context = Fixtures.context(width: 1, height: 1)
        context.setFillColor(CGColor(red: red, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()!
    }
}
