import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO

/// Self-test checks for the tools: several inputs in, several outputs out, and edits that keep
/// the source format, all through the sandboxed worker.
extension SelfTest.Checker {
    mutating func checkTools(png: URL) async {
        let catalog = ToolCatalog(writable: FileFormat.systemWritable())
        func tool(_ id: String) -> Tool { catalog.tools.first { $0.id == id }! }

        do {
            // Remove location from a JPEG that has GPS data.
            let photo = directory.appendingPathComponent("holiday.jpg")
            try SelfTest.makePhotoWithLocation().write(to: photo)
            let noLocation = directory.appendingPathComponent("holiday (no location).jpg")
            if await runTool(tool("image.removeLocation"), [photo], [.jpeg], to: noLocation) != nil {
                let gone = SelfTest.properties(noLocation)[kCGImagePropertyGPSDictionary] == nil
                report(gone && FileFormat.detect(at: noLocation) == .jpeg, "remove location", "GPS data still present")
            }

            // Rotate a JPEG and keep it a JPEG.
            let rotated = directory.appendingPathComponent("holiday (rotated).jpg")
            if await runTool(tool("image.rotateRight"), [photo], [.jpeg], to: rotated) != nil {
                let size = SelfTest.pixelSize(rotated)
                report(FileFormat.detect(at: rotated) == .jpeg && size == (48, 64), "rotate JPEG keep JPEG",
                       "got \(size.0)×\(size.1)")
            }

            // Merge two PDFs and a PNG into one PDF.
            let one = directory.appendingPathComponent("one.pdf")
            let three = directory.appendingPathComponent("three.pdf")
            try SelfTest.makePDF(pages: 1).write(to: one)
            try SelfTest.makePDF(pages: 3).write(to: three)
            let merged = directory.appendingPathComponent("one (merged).pdf")
            if await runTool(tool("pdf.merge"), [one, three, png], [.pdf, .pdf, .png], to: merged) != nil {
                let pages = SelfTest.pageCount(merged)
                report(pages == 5, "merge 2 PDFs + PNG", "got \(pages) pages")
            }

            // Split a 3-page PDF into a folder of three.
            let folder = directory.appendingPathComponent("three (pages)", isDirectory: true)
            if let result = await runTool(tool("pdf.split"), [three], [.pdf], to: folder) {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()) ?? []
                let ok = names == result.outputNames && names.count == 3
                    && names.allSatisfy { SelfTest.pageCount(folder.appendingPathComponent($0)) == 1 }
                report(ok, "split PDF into pages", "got \(names)")
            }
        } catch {
            report(false, "tools setup", error.localizedDescription)
        }
    }

    /// Runs a tool's request the way JobStore does. Returns the result on success.
    private mutating func runTool(_ tool: Tool, _ inputs: [URL], _ formats: [FileFormat], to destination: URL) async -> ConversionResult? {
        var request = tool.makeRequest(formats[0])
        if inputs.count > 1 { request.inputs = formats }
        do {
            return try await runner.run(inputs: inputs, destination: destination, request: request)
        } catch {
            report(false, tool.title, error.localizedDescription)
            return nil
        }
    }

    private mutating func report(_ passed: Bool, _ label: String, _ problem: String) {
        print(passed ? "PASS tool \(label)" : "FAIL tool \(label): \(problem)")
        if !passed { allPassed = false }
    }
}

extension SelfTest {
    /// A 64×48 JPEG with GPS coordinates.
    static func makePhotoWithLocation() throws -> Data {
        guard let context = CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw CocoaError(.featureUnsupported) }
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        guard let image = context.makeImage() else { throw CocoaError(.featureUnsupported) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw CocoaError(.featureUnsupported)
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 2.35, kCGImagePropertyGPSLongitudeRef: "E"],
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    static func makePDF(pages: Int) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw CocoaError(.featureUnsupported)
        }
        for _ in 0..<pages {
            var box = CGRect(x: 0, y: 0, width: 300, height: 200)
            context.beginPage(mediaBox: &box)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }

    static func pageCount(_ url: URL) -> Int {
        guard let provider = CGDataProvider(url: url as CFURL), let document = CGPDFDocument(provider) else { return 0 }
        return document.numberOfPages
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    static func pixelSize(_ url: URL) -> (Int, Int) {
        let properties = properties(url)
        return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }
}
