import AmeyaCore
import AppKit
import PDFKit

/// Converts between text documents (TXT, RTF, HTML, DOCX, DOC, ODT), renders them to PDF,
/// and extracts text from PDFs. Uses the system's own document readers and writers.
@MainActor
enum DocumentConverter {
    /// - Parameter languages: for text recognised in scanned PDF pages; `nil` uses the Mac's languages.
    static func convert(_ data: Data, from source: FileFormat, to target: FileFormat,
                        languages: [String]? = nil) throws -> (Data, [ConversionNote]) {
        // Markdown → HTML is rendered directly, which keeps semantic tags and code formatting.
        if source == .md && target == .html {
            return (Data(try MarkdownRenderer.html(decodeText(data)).utf8), [])
        }
        var notes: [ConversionNote] = []
        let text: NSAttributedString
        if source == .pdf {
            let recognised: Int
            (text, recognised) = try textOfPDF(data, languages: languages)
            notes.append(.onlyTextKept)
            if recognised > 0 { notes.append(.textRecognisedFromScans) }
        } else {
            var skipped = false
            text = try read(data, as: source, skippedExternal: &skipped)
            if skipped { notes.append(.externalResourcesSkipped) }
        }
        if target == .txt && source != .txt && source != .pdf {
            notes.append(.formattingRemoved)
        }
        if target == .md && source != .txt {
            notes.append(.markdownSimplified)
        }
        let output = target == .pdf ? try PaginatedPDF.render(text) : try write(text, as: target)
        return (output, notes)
    }

    static func documentType(for format: FileFormat) -> NSAttributedString.DocumentType? {
        switch format {
        case .txt: .plain
        case .rtf: .rtf
        case .html: .html
        case .docx: .officeOpenXML
        case .doc: .docFormat
        case .odt: .openDocument
        default: nil
        }
    }

    static func read(_ data: Data, as format: FileFormat) throws -> NSAttributedString {
        var skipped = false
        return try read(data, as: format, skippedExternal: &skipped)
    }

    /// Reads a document. HTML (and Markdown, which becomes HTML) is sanitized first, so the
    /// system reader has no outside file or web address to load; `skippedExternal` reports
    /// whether any such reference was removed.
    static func read(_ data: Data, as format: FileFormat, skippedExternal: inout Bool) throws -> NSAttributedString {
        if format == .txt {
            return NSAttributedString(string: decodeText(data), attributes: [
                .font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12),
            ])
        }
        var data = data
        if format == .md || format == .html {
            let html = format == .md ? try MarkdownRenderer.html(decodeText(data)) : decodeHTML(data)
            let sanitized = HTMLSanitizer.sanitize(html)
            skippedExternal = sanitized.removed
            data = Data(sanitized.html.utf8)
        }
        guard let type = documentType(for: format == .md ? .html : format) else { throw ConversionError.unreadable }
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        if format == .html || format == .md {
            options[.characterEncoding] = String.Encoding.utf8.rawValue
        }
        do {
            return try NSAttributedString(data: data, options: options, documentAttributes: nil)
        } catch {
            throw ConversionError.unreadable
        }
    }

    static func write(_ text: NSAttributedString, as format: FileFormat) throws -> Data {
        if format == .txt {
            return Data(text.string.utf8)
        }
        if format == .md {
            return Data(MarkdownWriter.markdown(from: text).utf8)
        }
        guard let type = documentType(for: format) else { throw ConversionError.unsupportedTarget(format) }
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if format == .html {
            attributes[.characterEncoding] = String.Encoding.utf8.rawValue
        }
        do {
            return try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
        } catch {
            throw ConversionError.encodeFailed(format)
        }
    }

    /// HTML text: the encoding its `<meta charset>` (or `http-equiv` content type) names when
    /// there is one and it decodes, otherwise a guess as for plain text.
    nonisolated static func decodeHTML(_ data: Data) -> String {
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        if !data.starts(with: [0xEF, 0xBB, 0xBF]), !data.starts(with: [0xFF, 0xFE]), !data.starts(with: [0xFE, 0xFF]),
           let range = head.range(of: "charset=") {
            let name = head[range.upperBound...].drop { $0 == "\"" || $0 == "'" || $0 == " " }
                .prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" || $0 == "." }
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(String(name) as CFString)
            if cfEncoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))) {
                return text
            }
        }
        return decodeText(data)
    }

    /// Plain text in an unknown encoding: let Foundation guess, preferring UTF-8.
    nonisolated static func decodeText(_ data: Data) -> String {
        var converted: NSString?
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [.suggestedEncodingsKey: [String.Encoding.utf8.rawValue]],
            convertedString: &converted,
            usedLossyConversion: nil
        )
        if encoding != 0, let converted { return converted as String }
        return String(decoding: data, as: UTF8.self)
    }

    /// The PDF's text, page by page. Pages without text (scans) are read with text recognition.
    /// Also returns how many pages were recognised.
    static func textOfPDF(_ data: Data, languages: [String]? = nil) throws -> (NSAttributedString, recognised: Int) {
        guard let document = PDFDocument(data: data) else { throw ConversionError.unreadable }
        if document.isLocked && !document.unlock(withPassword: "") { throw ConversionError.lockedPDF }
        let result = NSMutableAttributedString()
        var recognised = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var pageText = page.attributedString ?? NSAttributedString()
            if PDFOCR.needsRecognition(page) {
                let scanned = try PDFOCR.recognisedText(of: page, languages: languages, maxPixels: ConversionOptions.defaultMaxPixels)
                if !scanned.isEmpty {
                    pageText = NSAttributedString(string: scanned, attributes: [
                        .font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12),
                    ])
                    recognised += 1
                }
            }
            guard pageText.length > 0 else { continue }
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(pageText)
        }
        guard !result.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversionError.noText }
        return (result, recognised)
    }
}

/// Lays out rich text on A4 pages with the system text engine, which understands
/// tables, lists and embedded images from Word and HTML documents.
@MainActor
enum PaginatedPDF {
    static let pageSize = CGSize(width: 595.28, height: 841.89) // A4 in points
    static let margin: CGFloat = 56.7 // 2 cm
    static let maxPages = 5_000

    static func render(_ text: NSAttributedString) throws -> Data {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let textSize = CGSize(width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin)

        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: textSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let laidOut = layout.glyphRange(for: container)
            if NSMaxRange(laidOut) >= layout.numberOfGlyphs || containers.count >= maxPages { break }
        } while true

        let output = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ConversionError.encodeFailed(.pdf)
        }

        // Draw in the light appearance so "default" text colours come out black, even in Dark Mode.
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            for container in containers {
                context.beginPDFPage(nil)
                context.saveGState()
                context.translateBy(x: 0, y: pageSize.height)
                context.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                let glyphs = layout.glyphRange(for: container)
                let origin = CGPoint(x: margin, y: margin)
                layout.drawBackground(forGlyphRange: glyphs, at: origin)
                layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
                NSGraphicsContext.restoreGraphicsState()
                context.restoreGState()
                context.endPDFPage()
            }
        }
        context.closePDF()
        return output as Data
    }
}
