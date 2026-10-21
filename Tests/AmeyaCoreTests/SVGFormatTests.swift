import Foundation
import Testing
@testable import AmeyaCore

@Suite("SVG detection and routes")
struct SVGFormatTests {
    @Test("The root element identifies SVG", arguments: [
        #"<svg xmlns="http://www.w3.org/2000/svg"/>"#,
        "\u{FEFF}<?xml version=\"1.0\"?>\n<svg>",
        #"<?xml version="1.0" encoding="UTF-8"?><!-- made by hand --><svg width="1" height="1">"#,
        #"<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg>"#,
        #"<!DOCTYPE svg [ <!ATTLIST svg a CDATA "x>y"> ]>  <svg>"#,
        #"<svg:svg xmlns:svg="http://www.w3.org/2000/svg">"#,
    ])
    func sniffsSVG(text: String) {
        #expect(FileFormat.sniff(Data(text.utf8)) == .svg)
        #expect(FileFormat.detect(header: Data(text.utf8), fileExtension: "") == .svg)
    }

    @Test func utf16WithByteOrderMark() {
        var bytes: [UInt8] = [0xFF, 0xFE]
        for unit in "<?xml version=\"1.0\" encoding=\"UTF-16\"?><svg/>".utf16 { bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        #expect(FileFormat.sniff(Data(bytes)) == .svg)
    }

    @Test func otherXMLIsNotSVG() {
        #expect(FileFormat.sniff(Data(#"<?xml version="1.0"?><plist><svg/></plist>"#.utf8)) != .svg) // an XML plist is detected as .plist by the data engine
        #expect(FileFormat.sniff(Data("<svgx>".utf8)) == nil)
        #expect(FileFormat.sniff(Data("hello <svg>".utf8)) == nil)
        #expect(FileFormat.detect(header: Data("<html><svg/></html>".utf8), fileExtension: "svg") == .html)
        #expect(FileFormat.detect(header: Data("plain text".utf8), fileExtension: "svg") == nil)
    }

    @Test func rootPastTheHeaderUsesTheExtension() {
        let long = Data(("<!-- " + String(repeating: "x", count: 600) + " --><svg/>").utf8)
        #expect(FileFormat.detect(header: long.prefix(FileFormat.headerLength), fileExtension: "svg") == .svg)
        #expect(FileFormat.detect(header: long.prefix(FileFormat.headerLength), fileExtension: "txt") == .txt)
    }

    @Test func svgzIsGzipWithTheSVGZExtension() {
        let gzip = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0, 0x03])
        #expect(FileFormat.detect(header: gzip, fileExtension: "svgz") == .svg)
        #expect(FileFormat.detect(header: gzip, fileExtension: "gz") == .tgz)
        #expect(FileFormat.fromExtension("SVGZ") == .svg)
        #expect(FileFormat.svg.preferredExtension == "svg")
    }

    @Test func svgIsReadOnlyAndRoutesToImagesAndPDF() {
        #expect(!FileFormat.systemWritable().contains(.svg))
        let system = ConversionMatrix(writable: FileFormat.systemWritable())
        let targets = system.targets(for: .svg)
        #expect(targets.contains(.png) && targets.contains(.pdf) && targets.contains(.jpeg) && targets.contains(.tiff))
        #expect(!targets.contains(.mp4) && !targets.contains(.docx))
        #expect(!system.targets(for: .png).contains(.svg))
        #expect(system.possibleLosses(from: .svg, to: .jpeg) == [.transparencyFilledWhite])
        #expect(system.possibleLosses(from: .svg, to: .png).isEmpty)
    }

    @Test func rasterSizeOptionRoundTrips() throws {
        var options = ConversionOptions()
        options.rasterLongSide = 300
        let request = ConversionRequest(source: .svg, target: .png, options: options)
        #expect(try WorkerProtocol.decodeRequest(WorkerProtocol.encode(request)) == request)
        // Requests from before the field existed still decode.
        let legacy = #"{"target":"png","options":{"maxPixels":100,"maxFrames":1}}"#
        #expect(try WorkerProtocol.decodeRequest(legacy).options.rasterLongSide == nil)
    }
}
