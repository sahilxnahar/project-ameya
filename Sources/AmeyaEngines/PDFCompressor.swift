import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// Makes PDFs smaller by re-saving pages that are mostly pictures (scans, photo pages) as JPEG at a
/// resolution set by `quality`; pages with real text stay vector and selectable. Never returns a
/// bigger file: when nothing shrinks, the original bytes come back with `.alreadySmallEnough`.
enum PDFCompressor {
    /// A page counts as "mostly pictures" with at least this many image pixels…
    static let minimumImagePixels = 100_000
    /// …and less selectable text than this (a scan's page number, a caption).
    static let maximumTextCharacters = 200
    /// Longest side of a re-rendered page, in pixels, whatever the page size.
    static let maximumRenderSide = 6_000.0

    /// Resolution for a quality: 150 dpi at 0.7, never below 72 dpi or above 300.
    static func dpi(for quality: Double) -> Double {
        min(300, max(72, (quality * 215).rounded()))
    }

    static func compress(
        input: URL, quality: Double, targetBytes: Int?, scratch: URL, progress: (Double) -> Void
    ) throws -> (output: URL, pages: Int, notes: [ConversionNote]) {
        guard (0.05...1).contains(quality) else { throw ConversionError.invalidData("the quality must be between 0.05 and 1") }
        if let targetBytes, targetBytes <= 0 { throw ConversionError.invalidData("the size target must be above zero") }
        let output = scratch.appendingPathComponent("output.pdf")
        let originalBytes = VideoEditor.fileSize(input)
        let probe = try PDFTools.open(input)
        let pages = probe.pageCount
        let pictures = (0..<pages).filter { index in probe.page(at: index).map(isMostlyPictures) ?? false }

        func keepOriginal() throws -> (output: URL, pages: Int, notes: [ConversionNote]) {
            try FileManager.default.copyItem(at: input, to: output)
            progress(1)
            return (output, pages, [.alreadySmallEnough])
        }
        if pictures.isEmpty { return try keepOriginal() }
        if let targetBytes, originalBytes <= targetBytes { return try keepOriginal() }

        // With a size target, step down until it fits.
        var qualities = [quality]
        if targetBytes != nil {
            qualities += [0.7, 0.5, 0.35, 0.25, 0.15].map { $0 * quality / 0.7 }.filter { $0 < quality - 0.01 && $0 >= 0.1 }
        }
        var best: (url: URL, bytes: Int)?
        for (attempt, level) in qualities.enumerated() {
            let document = try PDFTools.open(input) // fresh pages for every attempt
            var keepAlive: [PDFDocument] = []
            for (step, index) in pictures.enumerated() {
                guard let page = document.page(at: index) else { throw ConversionError.unreadable }
                let (replacement, owner) = try rendered(page, dpi: dpi(for: level), jpegQuality: level)
                keepAlive.append(owner)
                for annotation in page.annotations {
                    page.removeAnnotation(annotation)
                    replacement.addAnnotation(annotation)
                }
                document.removePage(at: index)
                document.insert(replacement, at: index)
                let done = Double(attempt) + Double(step + 1) / Double(pictures.count)
                progress(min(0.99, done / Double(qualities.count)))
            }
            let url = scratch.appendingPathComponent("attempt-\(attempt).pdf")
            guard document.write(to: url) else { throw ConversionError.encodeFailed(.pdf) }
            withExtendedLifetime(keepAlive) {}
            let bytes = VideoEditor.fileSize(url)
            if best == nil || bytes < best!.bytes {
                if let previous = best { try? FileManager.default.removeItem(at: previous.url) }
                best = (url, bytes)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
            if let targetBytes, bytes > targetBytes { continue }
            break
        }

        guard let best, best.bytes < originalBytes else {
            if let best { try? FileManager.default.removeItem(at: best.url) }
            return try keepOriginal()
        }
        try FileManager.default.moveItem(at: best.url, to: output)
        var notes: [ConversionNote] = [.pdfPagesRecompressed]
        if let targetBytes, best.bytes > targetBytes { notes.append(.targetSizeNotReached) }
        progress(1)
        return (output, pages, notes)
    }

    // MARK: Finding picture pages

    /// Big images and almost no text: a scan or a photo page.
    static func isMostlyPictures(_ page: PDFPage) -> Bool {
        guard let dictionary = page.pageRef?.dictionary else { return false }
        let text = (page.string ?? "").filter { !$0.isWhitespace }
        return text.count < maximumTextCharacters && imagePixels(in: dictionary, depth: 0) >= minimumImagePixels
    }

    /// Pixels of every image XObject in a page's (or form's) resources, following nested forms.
    static func imagePixels(in dictionary: CGPDFDictionaryRef, depth: Int) -> Int {
        var resources: CGPDFDictionaryRef?
        var xObjects: CGPDFDictionaryRef?
        guard depth < 4, CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return 0 }
        var total = 0
        CGPDFDictionaryApplyBlock(xObjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let streamDictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype), let subtype else { return true }
            switch String(cString: subtype) {
            case "Image":
                var width: CGPDFInteger = 0, height: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(streamDictionary, "Width", &width)
                CGPDFDictionaryGetInteger(streamDictionary, "Height", &height)
                total += max(0, width) * max(0, height)
            case "Form":
                total += imagePixels(in: streamDictionary, depth: depth + 1)
            default:
                break
            }
            return true
        }, nil)
        return total
    }

    // MARK: Re-rendering

    /// The page drawn into a JPEG at `dpi`, placed on a page of the same size, crop and rotation.
    /// Returns the page and the one-page document that owns it (keep it alive until saved).
    static func rendered(_ page: PDFPage, dpi: Double, jpegQuality: Double) throws -> (PDFPage, PDFDocument) {
        guard let cgPage = page.pageRef else { throw ConversionError.unreadable }
        let media = cgPage.getBoxRect(.mediaBox)
        guard media.width > 0, media.height > 0 else { throw ConversionError.unreadable }
        let scale = min(dpi / 72, maximumRenderSide / max(media.width, media.height))
        let width = max(1, Int((media.width * scale).rounded()))
        let height = max(1, Int((media.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConversionError.tooLarge(pixels: width * height, limit: width * height)
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / media.width, y: CGFloat(height) / media.height)
        context.translateBy(x: -media.minX, y: -media.minY)
        context.drawPDFPage(cgPage)
        guard let bitmap = context.makeImage() else { throw ConversionError.encodeFailed(.pdf) }

        // A JPEG-backed CGImage goes into the PDF as-is (DCTDecode), so the page is the JPEG's size.
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil) else {
            throw ConversionError.encodeFailed(.jpeg)
        }
        CGImageDestinationAddImage(destination, bitmap, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: jpeg as CFData),
              let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw ConversionError.encodeFailed(.jpeg)
        }

        let pdf = NSMutableData()
        var box = media
        guard let consumer = CGDataConsumer(data: pdf), let writer = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw ConversionError.encodeFailed(.pdf)
        }
        writer.beginPage(mediaBox: &box)
        writer.draw(image, in: media)
        writer.endPage()
        writer.closePDF()
        guard let document = PDFDocument(data: pdf as Data), let replacement = document.page(at: 0) else {
            throw ConversionError.encodeFailed(.pdf)
        }
        replacement.setBounds(page.bounds(for: .cropBox), for: .cropBox)
        replacement.rotation = page.rotation
        return (replacement, document)
    }
}
