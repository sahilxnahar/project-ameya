import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO

/// Self-test checks for the photo tools, through the sandboxed worker: edit, redact (pixels and
/// metadata), add background, watermark with a logo as the second input, and remove background.
extension SelfTest.Checker {
    mutating func checkPhotoTools() async {
        let catalog = ToolCatalog(writable: FileFormat.systemWritable())
        func tool(_ id: String) -> Tool { catalog.tools.first { $0.id == id }! }

        do {
            let photo = directory.appendingPathComponent("street.jpg") // 64×48 with GPS
            try SelfTest.makePhotoWithLocation().write(to: photo)

            let edited = directory.appendingPathComponent("street (edited).jpg")
            if await runPhotoTool(tool("image.editPhoto"), [photo], .jpeg, to: edited,
                                  edits: .photo(adjustments: PhotoAdjustments(exposure: 0.6))) != nil {
                let brighter = SelfTest.meanBrightness(edited) > SelfTest.meanBrightness(photo) + 5
                photoReport(brighter && FileFormat.detect(at: edited) == .jpeg, "edit photo brightens", "not brighter")
            }

            let redacted = directory.appendingPathComponent("street (redacted).jpg")
            let box = UnitRect(x: 0, y: 0, width: 0.5, height: 0.5)
            if let result = await runPhotoTool(tool("image.redact"), [photo], .jpeg, to: redacted,
                                               edits: .photo(redaction: Redaction(boxes: [box], style: .black), metadata: .removeAll)) {
                let properties = SelfTest.properties(redacted)
                let clean = properties[kCGImagePropertyGPSDictionary] == nil && result.notes.contains(.redactionBurnedIn)
                let black = SelfTest.meanBrightness(redacted, in: CGRect(x: 2, y: 2, width: 26, height: 18)) < 8
                photoReport(clean && black, "redact covers and strips metadata", "clean \(clean), black \(black)")
            }

            let framed = directory.appendingPathComponent("street (framed).png")
            if await runPhotoTool(tool("image.beautify"), [photo], .jpeg, to: framed, target: .png,
                                  edits: .photo(beautify: Beautify(padding: 0.25, backdrop: .ocean))) != nil {
                let size = SelfTest.pixelSize(framed)
                photoReport(size == (96, 80), "add background pads", "got \(size.0)×\(size.1)")
            }

            let logo = directory.appendingPathComponent("logo.png")
            try SelfTest.solidPNG(width: 40, height: 20, red: 1, green: 0, blue: 0).write(to: logo)
            let marked = directory.appendingPathComponent("street (watermarked).jpg")
            if await runPhotoTool(tool("image.watermark"), [photo, logo], .jpeg, to: marked,
                                  edits: .photo(watermark: Watermark(useLogo: true, position: .bottomRight, opacity: 1, size: 0.4)),
                                  extraFormats: [.png]) != nil {
                let corner = SelfTest.meanColour(marked, in: CGRect(x: 40, y: 34, width: 18, height: 8))
                photoReport(corner.red > 180 && corner.green < 90, "watermark with a logo", "corner \(corner)")
            }

            let subject = directory.appendingPathComponent("plain.png")
            try SelfTest.solidPNG(width: 200, height: 200, red: 0.5, green: 0.5, blue: 0.5).write(to: subject)
            let cutout = directory.appendingPathComponent("plain (no background).png")
            var request = tool("image.removeBackground").makeRequest(.png)
            request.options.image = .photo(removeBackground: BackgroundRemoval())
            do {
                _ = try await runner.run(inputs: [subject], destination: cutout, request: request)
                photoReport(false, "remove background refuses a plain picture", "made a cut-out of nothing")
            } catch {
                let friendly = error.localizedDescription.contains("No clear subject")
                photoReport(friendly, "remove background explains a missing subject", error.localizedDescription)
            }
        } catch {
            photoReport(false, "photo tools setup", error.localizedDescription)
        }
    }

    /// Runs a photo tool the way JobStore does, with the panel's edits.
    private mutating func runPhotoTool(_ tool: Tool, _ inputs: [URL], _ format: FileFormat, to destination: URL,
                                       target: FileFormat? = nil, edits: ImageEdits,
                                       extraFormats: [FileFormat] = []) async -> ConversionResult? {
        var request = tool.makeRequest(format)
        request.options.image = edits
        if let target { request.target = target }
        if inputs.count > 1 { request.inputs = [format] + extraFormats }
        do {
            return try await runner.run(inputs: inputs, destination: destination, request: request)
        } catch {
            photoReport(false, tool.title, error.localizedDescription)
            return nil
        }
    }

    private mutating func photoReport(_ passed: Bool, _ label: String, _ problem: String) {
        print(passed ? "PASS photo \(label)" : "FAIL photo \(label): \(problem)")
        if !passed { allPassed = false }
    }
}

extension SelfTest {
    static func solidPNG(width: Int, height: Int, red: Double, green: Double, blue: Double) throws -> Data {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.featureUnsupported) }
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.featureUnsupported)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    /// Average sRGB colour (0…255) in a rectangle given with a top-left origin; the whole picture by default.
    static func meanColour(_ url: URL, in rect: CGRect? = nil) -> (red: Double, green: Double, blue: Double) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return (0, 0, 0) }
        let (width, height) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let area = (rect ?? CGRect(x: 0, y: 0, width: width, height: height))
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        var total = (0.0, 0.0, 0.0), count = 0.0
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) {
                let i = (y * width + x) * 4
                total.0 += Double(bytes[i]); total.1 += Double(bytes[i + 1]); total.2 += Double(bytes[i + 2])
                count += 1
            }
        }
        guard count > 0 else { return (0, 0, 0) }
        return (total.0 / count, total.1 / count, total.2 / count)
    }

    static func meanBrightness(_ url: URL, in rect: CGRect? = nil) -> Double {
        let colour = meanColour(url, in: rect)
        return (colour.red + colour.green + colour.blue) / 3
    }
}
