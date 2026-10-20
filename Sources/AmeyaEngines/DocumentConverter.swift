import AmeyaCore
import AppKit
import PDFKit

/// Converts between text documents (TXT, RTF, HTML, DOCX, DOC, ODT), renders them to PDF,
/// and extracts text from PDFs. Uses the system's own document readers and writers.
@MainActor
enum DocumentConverter {
    static func convert(_ data: Data, from source: FileFormat, to target: FileFormat) throws -> (Data, [ConversionNote]) {
        // Markdown → HTML is rendered directly, which keeps semantic tags and code formatting.
        if source == .md && target == .html {
            return (Data(try MarkdownRenderer.html(decodeText(data)).utf8), [])
        }
        var notes: [ConversionNote] = []
        let text: NSAttributedString
        if source == .pdf {
            text = try textOfPDF(data)
            notes.append(.onlyTextKept)
        } else {
            text = try read(data, as: source)
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
        if format == .txt {
            return NSAttributedString(string: decodeText(data), attributes: [
                .font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12),
            ])
        }
        if format == .md {
            let html = try MarkdownRenderer.html(decodeText(data))
            return try read(Data(html.utf8), as: .html)
        }
        guard let type = documentType(for: format) else { throw ConversionError.unreadable }
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        if format == .html {
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

    static func textOfPDF(_ data: Data) throws -> NSAttributedString {
        guard let document = PDFDocument(data: data) else { throw ConversionError.unreadable }
        if document.isLocked && !document.unlock(withPassword: "") { throw ConversionError.lockedPDF }
        let result = NSMutableAttributedString()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let pageText = page.attributedString, pageText.length > 0 else { continue }
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(pageText)
        }
        guard !result.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversionError.noText }
        return result
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
