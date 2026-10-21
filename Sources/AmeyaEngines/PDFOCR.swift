import AmeyaCore
import AppKit
import CoreText
import Foundation
import PDFKit

/// Makes scanned PDFs searchable and copies text out of scans and pictures, on this Mac (Vision).
///
/// A page is treated as scanned when it has fewer than `minimumTextCharacters` of real text.
/// Its original content is kept as it is (vectors included); an invisible text layer is drawn on
/// top, line by line, so the page looks the same but its text can be searched, selected and copied.
@MainActor
enum PDFOCR {
    /// Scans are read at 300 dpi…
    static let dpi: CGFloat = 300
    /// …unless the page would exceed this many pixels (Vision gains little beyond it).
    static let maxRecognitionPixels = 40_000_000
    static let minimumTextCharacters = 10

    // MARK: Searchable PDF

    /// Adds a text layer to every page that needs one. Returns the number of pages recognised.
    @discardableResult
    static func makeSearchable(_ document: PDFDocument, languages: [String]?, maxPixels: Int,
                               progress: (Double) -> Void = { _ in }) throws -> Int {
        var recognised = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), needsRecognition(page),
                  let replacement = try searchableCopy(of: page, languages: languages, maxPixels: maxPixels) else {
                progress(Double(index + 1) / Double(document.pageCount))
                continue
            }
            PDFToolbox.replace(page, with: replacement, at: index, in: document) // keeps links, notes, bookmarks
            recognised += 1
            progress(Double(index + 1) / Double(document.pageCount))
        }
        return recognised
    }

    static func needsRecognition(_ page: PDFPage) -> Bool {
        let characters = (page.string ?? "").unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        return characters.count < minimumTextCharacters
    }

    /// The page drawn as it is, plus invisible recognised text. `nil` when no text was found.
    static func searchableCopy(of page: PDFPage, languages: [String]?, maxPixels: Int) throws -> PDFPage? {
        guard let source = page.pageRef else { throw ConversionError.unreadable }
        let (image, pageToPixel) = try render(source, maxPixels: maxPixels)
        let lines = try TextRecognizer.recognize(image, languages: languages)
        guard !lines.isEmpty else { return nil }
        // The original is embedded as is, so vectors and fonts stay sharp.
        return try PDFToolbox.redraw(page) { context, _ in
            drawInvisible(lines, imageSize: CGSize(width: image.width, height: image.height),
                          pixelToPage: pageToPixel.inverted(), in: context)
        }
    }

    /// Draws each line in text render mode 3 (invisible), stretched over the line's box.
    static func drawInvisible(_ lines: [RecognizedLine], imageSize: CGSize, pixelToPage: CGAffineTransform, in context: CGContext) {
        context.saveGState()
        context.concatenate(pixelToPage)
        context.setTextDrawingMode(.invisible)
        for line in lines {
            let box = CGRect(x: line.box.minX * imageSize.width, y: line.box.minY * imageSize.height,
                             width: line.box.width * imageSize.width, height: line.box.height * imageSize.height)
            guard box.width >= 1, box.height >= 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, box.height, nil)
            let attributed = NSAttributedString(string: line.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
            guard width > 0, ascent + descent > 0 else { continue }
            let vertical = box.height / (ascent + descent)
            context.saveGState()
            context.translateBy(x: box.minX, y: box.minY + descent * vertical)
            context.scaleBy(x: box.width / width, y: vertical)
            context.textPosition = .zero
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// Renders an upright page at `dpi` (less for huge pages). Also returns the transform from the
    /// page's own coordinates to the image's pixels, to place text back where it was found.
    static func render(_ page: CGPDFPage, maxPixels: Int) throws -> (CGImage, CGAffineTransform) {
        let box = page.getBoxRect(.cropBox)
        let quarterTurns = ((page.rotationAngle % 360) + 360) % 360 / 90
        let size = quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width >= 1, size.height >= 1 else { throw ConversionError.unreadable }

        var scale = dpi / 72
        let limit = Double(min(maxPixels, maxRecognitionPixels))
        let pixels = Double(size.width * scale) * Double(size.height * scale)
        if pixels > limit { scale *= CGFloat((limit / pixels).squareRoot()) }
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConversionError.tooLarge(pixels: width * height, limit: maxPixels)
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        // Same placement as PDFRasterizer: getDrawingTransform handles crop origin and rotation.
        let drawing = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
        let pageToPixel = drawing.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        context.concatenate(pageToPixel)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ConversionError.unreadable }
        return (image, pageToPixel)
    }

    // MARK: Text out

    /// The recognised text of one page ("" when none was found).
    static func recognisedText(of page: PDFPage, languages: [String]?, maxPixels: Int) throws -> String {
        guard let source = page.pageRef else { throw ConversionError.unreadable }
        let (image, _) = try render(source, maxPixels: maxPixels)
        return TextRecognizer.text(of: try TextRecognizer.recognize(image, languages: languages))
    }

    /// Text targets "Copy text from image" and scanned-PDF text can be written to.
    static let textTargets: Set<FileFormat> = [.txt, .docx, .md, .rtf, .html]

    /// Plain recognised text as a document of `target`'s format.
    static func document(_ text: String, as target: FileFormat) throws -> Data {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12),
        ])
        return try DocumentConverter.write(attributed, as: target)
    }
}
