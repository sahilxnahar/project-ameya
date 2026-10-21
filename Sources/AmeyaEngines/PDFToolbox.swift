import AmeyaCore
import AppKit
import CoreText
import Foundation
import PDFKit

/// PDF tools that change what is on the pages or who can open them: text recognition, page
/// numbers, watermarks and passwords. Page-level tools (merge, split, …) live in `PDFTools`.
@MainActor
public enum PDFToolbox {
    public static func handles(_ action: AmeyaCore.PDFAction) -> Bool {
        switch action {
        case .ocr, .addPageNumbers, .watermark, .protect, .removePassword: true
        default: false
        }
    }

    public static func run(
        _ action: AmeyaCore.PDFAction,
        inputs: [URL],
        request: ConversionRequest,
        scratch: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> (outputs: [URL], result: ConversionResult) {
        guard inputs.count == 1 else { throw ConversionError.invalidData("this PDF tool takes one file at a time") }
        let input = inputs[0]
        let source = request.source ?? FileFormat.detect(at: input) ?? .pdf
        let target = request.target
        let options = request.options

        if case .ocr(let languages) = action {
            return try recognise(input, from: source, to: target, languages: languages, options: options,
                                 scratch: scratch, progress: progress)
        }
        guard source == .pdf, target == .pdf else { throw ConversionError.unsupportedConversion(from: source, to: target) }

        switch action {
        case .addPageNumbers(let style):
            let document = try PDFTools.open(input)
            let total = document.pageCount
            try stampEveryPage(document, progress: progress) { context, size, index in
                drawPageNumber(style.label(page: index + 1, of: total), on: size, in: context)
            }
            return try finish(document, in: scratch, notes: [])

        case .watermark(let text, let opacity):
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { throw ConversionError.invalidData("the watermark text is empty") }
            guard words.count <= 200 else { throw ConversionError.invalidData("the watermark text is longer than 200 characters") }
            let document = try PDFTools.open(input)
            let alpha = min(max(opacity, 0.05), 1)
            try stampEveryPage(document, progress: progress) { context, size, _ in
                drawWatermark(words, opacity: alpha, on: size, in: context)
            }
            return try finish(document, in: scratch, notes: [])

        case .protect(let password):
            let (output, notes) = try PDFPasswords.protect(input, password: password, scratch: scratch, progress: progress)
            return ([output], result(output, pages: Self.pageCount(output, password: password), notes: notes))

        case .removePassword(let password):
            let output = try PDFPasswords.remove(input, password: password, scratch: scratch)
            progress(1)
            return ([output], result(output, pages: Self.pageCount(output, password: nil), notes: []))

        case .ocr, .merge, .splitEveryPage, .splitRanges, .rotate, .deletePages, .reorder, .compress:
            throw ConversionError.unsupportedConversion(from: source, to: target)
        }
    }

    // MARK: Text recognition

    private static func recognise(
        _ input: URL, from source: FileFormat, to target: FileFormat, languages: [String]?,
        options: ConversionOptions, scratch: URL, progress: @escaping @Sendable (Double) -> Void
    ) throws -> (outputs: [URL], result: ConversionResult) {
        let data: Data
        do { data = try Data(contentsOf: input, options: .mappedIfSafe) } catch { throw ConversionError.unreadable }

        switch (source, target) {
        case (.pdf, .pdf):
            let document = try PDFTools.open(input)
            guard (0..<document.pageCount).contains(where: { document.page(at: $0).map(PDFOCR.needsRecognition) ?? false }) else {
                throw ConversionError.refused("This PDF is already searchable: every page has text.")
            }
            let pages = try PDFOCR.makeSearchable(document, languages: languages, maxPixels: options.maxPixels, progress: progress)
            guard pages > 0 else { throw ConversionError.noText }
            return try finish(document, in: scratch, notes: [.scannedPagesMadeSearchable], frames: pages)

        case (.pdf, _) where PDFOCR.textTargets.contains(target):
            let (output, notes) = try DocumentConverter.convert(data, from: .pdf, to: target, languages: languages)
            return try save(output, as: target, in: scratch, notes: notes, frames: 1, progress: progress)

        case (_, .pdf) where source.family == .image:
            var imageOptions = options
            imageOptions.pdf = nil
            let (pdf, _) = try ImageConverter.convert(data, request: ConversionRequest(source: source, target: .pdf, options: imageOptions))
            guard let document = PDFDocument(data: pdf) else { throw ConversionError.encodeFailed(.pdf) }
            let pages = try PDFOCR.makeSearchable(document, languages: languages, maxPixels: options.maxPixels, progress: progress)
            guard pages > 0 else { throw ConversionError.noText }
            return try finish(document, in: scratch, notes: [.scannedPagesMadeSearchable], frames: pages)

        case (_, _) where source.family == .image && PDFOCR.textTargets.contains(target):
            let decoded = SVGRenderer.looksLikeSVG(data)
                ? try SVGRenderer.decode(data, options: options).0
                : try ImageDecoder.decode(data, options: options)
            var pages: [String] = []
            for (index, frame) in decoded.frames.enumerated() {
                let text = TextRecognizer.text(of: try TextRecognizer.recognize(frame.image, languages: languages))
                if !text.isEmpty { pages.append(text) }
                progress(Double(index + 1) / Double(decoded.frames.count))
            }
            guard !pages.isEmpty else { throw ConversionError.noText }
            let text = pages.joined(separator: "\n\n") + (target == .txt ? "\n" : "")
            return try save(try PDFOCR.document(text, as: target), as: target, in: scratch,
                            notes: [.textRecognisedInPicture], frames: decoded.frames.count, progress: progress)

        default:
            throw ConversionError.unsupportedConversion(from: source, to: target)
        }
    }

    // MARK: Stamping

    /// Redraws every page with `overlay` on top, in upright page space of the given size.
    static func stampEveryPage(_ document: PDFDocument, progress: (Double) -> Void,
                               overlay: (CGContext, CGSize, Int) -> Void) throws {
        let pages = try (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else { throw ConversionError.unreadable }
            return page
        }
        // One drawing context for all pages, so fonts and pictures they share are stored once.
        let copies = try redraw(pages) { context, source, index in
            let (size, uprightToPage) = upright(source)
            context.saveGState()
            context.concatenate(uprightToPage)
            overlay(context, size, index)
            context.restoreGState()
            progress(Double(index + 1) / Double(pages.count) * 0.9)
        }
        for (index, (page, copy)) in zip(pages, copies).enumerated() {
            replace(page, with: copy, at: index, in: document)
        }
    }

    /// One page. See `redraw(_:overlay:)` for several.
    static func redraw(_ page: PDFPage, overlay: (CGContext, CGPDFPage) -> Void) throws -> PDFPage {
        try redraw([page]) { context, source, _ in overlay(context, source) }[0]
    }

    /// New pages with the same boxes and rotation: each original's content (kept as vectors), then
    /// `overlay` drawn in that page's own coordinates.
    static func redraw(_ pages: [PDFPage], overlay: (CGContext, CGPDFPage, Int) -> Void) throws -> [PDFPage] {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ConversionError.encodeFailed(.pdf)
        }
        for (index, page) in pages.enumerated() {
            guard let source = page.pageRef else { throw ConversionError.unreadable }
            var mediaBox = source.getBoxRect(.mediaBox)
            var cropBox = source.getBoxRect(.cropBox)
            let boxes: [CFString: Any] = [
                kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size) as CFData,
                kCGPDFContextCropBox: Data(bytes: &cropBox, count: MemoryLayout<CGRect>.size) as CFData,
            ]
            context.beginPDFPage(boxes as CFDictionary)
            context.drawPDFPage(source)
            overlay(context, source, index)
            context.endPDFPage()
        }
        context.closePDF()
        guard let redrawn = PDFDocument(data: output as Data), redrawn.pageCount == pages.count else {
            throw ConversionError.encodeFailed(.pdf)
        }
        return try pages.enumerated().map { index, page in
            guard let copy = redrawn.page(at: index) else { throw ConversionError.encodeFailed(.pdf) }
            copy.rotation = page.rotation
            return copy
        }
    }

    /// Swaps `page` for `copy`, moving its links, notes and bookmarks along.
    static func replace(_ page: PDFPage, with copy: PDFPage, at index: Int, in document: PDFDocument) {
        for annotation in page.annotations {
            page.removeAnnotation(annotation)
            copy.addAnnotation(annotation)
        }
        var outlines: [PDFOutline] = []
        if let root = document.outlineRoot { collect(root, pointingTo: page, into: &outlines) }
        document.removePage(at: index)
        document.insert(copy, at: index)
        for item in outlines {
            item.destination = PDFDestination(page: copy, at: item.destination?.point ?? .zero)
        }
    }

    private static func collect(_ item: PDFOutline, pointingTo page: PDFPage, into found: inout [PDFOutline]) {
        if item.destination?.page === page { found.append(item) }
        for child in 0..<item.numberOfChildren {
            if let next = item.child(at: child) { collect(next, pointingTo: page, into: &found) }
        }
    }

    /// The size of the page as shown (after rotation) and the transform from that upright space,
    /// origin bottom-left, to the page's own coordinates.
    static func upright(_ page: CGPDFPage) -> (CGSize, CGAffineTransform) {
        let box = page.getBoxRect(.cropBox)
        let quarterTurns = ((page.rotationAngle % 360) + 360) % 360 / 90
        let size = quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
        let pageToUpright = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
        return (size, pageToUpright.inverted())
    }

    static func drawPageNumber(_ label: String, on size: CGSize, in context: CGContext) {
        let fontSize = max(6, min(10, size.width / 40))
        let line = textLine(label, font: CTFontCreateWithName("Helvetica" as CFString, fontSize, nil),
                            color: CGColor(gray: 0.25, alpha: 1))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textPosition = CGPoint(x: (size.width - width) / 2, y: max(fontSize * 1.8, size.height * 0.025))
        CTLineDraw(line, context)
    }

    static func drawWatermark(_ text: String, opacity: Double, on size: CGSize, in context: CGContext) {
        let angle = atan2(size.height, size.width)
        let diagonal = (size.width * size.width + size.height * size.height).squareRoot()
        let probe = textLine(text, font: CTFontCreateWithName("Helvetica-Bold" as CFString, 100, nil), color: CGColor(gray: 0, alpha: 1))
        let probeWidth = max(1, CGFloat(CTLineGetTypographicBounds(probe, nil, nil, nil)))
        let fontSize = min(100 * diagonal * 0.7 / probeWidth, size.height / 3)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let line = textLine(text, font: font, color: CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: opacity))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.saveGState()
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: angle)
        context.textPosition = CGPoint(x: -width / 2, y: -(CTFontGetAscent(font) - CTFontGetDescent(font)) / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func textLine(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
    }

    // MARK: Output

    private static func finish(_ document: PDFDocument, in scratch: URL, notes: [ConversionNote],
                               frames: Int? = nil) throws -> (outputs: [URL], result: ConversionResult) {
        let output = scratch.appendingPathComponent("output.pdf")
        guard document.write(to: output) else { throw ConversionError.encodeFailed(.pdf) }
        return ([output], result(output, pages: frames ?? document.pageCount, notes: notes))
    }

    private static func save(_ data: Data, as target: FileFormat, in scratch: URL, notes: [ConversionNote], frames: Int,
                             progress: (Double) -> Void) throws -> (outputs: [URL], result: ConversionResult) {
        let output = scratch.appendingPathComponent("output.\(target.preferredExtension)")
        try data.write(to: output)
        progress(1)
        return ([output], result(output, pages: frames, notes: notes))
    }

    private static func pageCount(_ url: URL, password: String?) -> Int {
        guard let document = PDFDocument(url: url) else { return 0 }
        if let password { _ = document.unlock(withPassword: password) }
        return document.pageCount
    }

    private static func result(_ output: URL, pages: Int, notes: [ConversionNote]) -> ConversionResult {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        return ConversionResult(outputBytes: bytes, frames: pages, notes: notes)
    }
}
