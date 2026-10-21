import AmeyaCore
import AppKit
import Foundation

/// Routes conversions that involve an e-book or a comic.
@MainActor
enum BookConverter {
    static func convert(
        input: URL, from source: FileFormat, to target: FileFormat, output: URL,
        options: ConversionOptions, progress: @escaping (Double) -> Void
    ) throws -> (notes: [ConversionNote], frames: Int) {
        switch (source, target) {
        case (.epub, _):
            let (data, notes) = try EbookConverter.convert(input: input, to: target)
            try data.write(to: output)
            progress(1)
            return (notes, 1)
        case (_, .epub):
            let notes = try EbookWriter.write(try Data(contentsOf: input), from: source, to: output)
            progress(1)
            return (notes, 1)
        case (.cbz, .pdf), (.cbr, .pdf):
            return try ComicConverter.toPDF(input: input, output: output, options: options, progress: progress)
        case (.cbr, .cbz):
            return try ComicConverter.repack(input: input, output: output, options: options, progress: progress)
        case (.pdf, .cbz):
            return try ComicConverter.fromPDF(input: input, output: output, options: options, progress: progress)
        default:
            throw ConversionError.unsupportedConversion(from: source, to: target)
        }
    }
}

/// Reads EPUB 2 and 3 books: container.xml → package (OPF) → spine, then joins the chapters
/// into one HTML document that the system document engine turns into PDF, Word, RTF and so on.
/// Pictures are embedded as data: URLs; scripts, styles and anything that would reach outside
/// the book are removed.
@MainActor
enum EbookConverter {
    static let limits = ArchiveEntries.Limits(maxEntries: 20_000, maxTotalBytes: 500 << 20)

    struct Book {
        var title: String?
        var authors: [String] = []
        var language: String?
        /// Each chapter's body content, as XHTML.
        var chapters: [String] = []
        var droppedImages = false
    }

    static func convert(input: URL, to target: FileFormat) throws -> (Data, [ConversionNote]) {
        let wantsImages = target != .txt && target != .md
        let book = try read(input, embedImages: wantsImages)
        var notes: [ConversionNote] = switch target {
        case .txt: [.formattingRemoved]
        case .md: [.markdownSimplified]
        default: [.bookLayoutReflowed]
        }
        if book.droppedImages { notes.append(.imagesDropped) }

        let html = combinedHTML(book)
        if target == .html { return (Data(html.utf8), notes) }
        let text = try DocumentConverter.read(Data(html.utf8), as: .html)
        guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target != .txt else {
            throw ConversionError.noText
        }
        if target == .pdf {
            return (try PaginatedPDF.render(fittingPictures(text)), notes)
        }
        return (try DocumentConverter.write(text, as: target), notes)
    }

    static func read(_ input: URL, embedImages: Bool = true) throws -> Book {
        let archive = try ArchiveEntries.read(input, limits: limits)
        if try isDRMProtected(archive) { throw BookError.drmProtected }

        guard let containerData = archive["META-INF/container.xml"] else {
            throw BookError.notABook("META-INF/container.xml is missing")
        }
        let container = try parseXML(containerData, part: "container.xml")
        guard let rootPath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue,
              let opfPath = XHTML.resolve(rootPath, from: "") else {
            throw BookError.notABook("container.xml doesn't name the package file")
        }
        guard let opfData = archive[opfPath] else { throw BookError.missingPart(opfPath) }
        let opf = try parseXML(opfData, part: opfPath)
        let opfDirectory = XHTML.directory(of: opfPath)

        var book = Book()
        func metadata(_ name: String) throws -> [String] {
            try opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='\(name)']")
                .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        book.title = try metadata("title").first
        book.authors = try metadata("creator")
        book.language = try metadata("language").first

        var manifest: [String: (path: String, type: String)] = [:]
        var types: [String: String] = [:]
        for case let item as XMLElement in try opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            guard let id = item.attribute(forName: "id")?.stringValue,
                  let href = item.attribute(forName: "href")?.stringValue,
                  let path = XHTML.resolve(href, from: opfDirectory) else { continue }
            let type = item.attribute(forName: "media-type")?.stringValue ?? ""
            manifest[id] = (path, type)
            types[path] = type
        }
        let spine = try opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']/@idref")
            .compactMap { $0.stringValue.flatMap { manifest[$0] } }
            .filter { $0.type.contains("html") || $0.type.isEmpty }
        guard !spine.isEmpty else { throw BookError.notABook("it has no chapters") }

        for part in spine {
            guard let data = archive[part.path] else { throw BookError.missingPart(part.path) }
            let body = try chapterBody(data, path: part.path, archive: archive, types: types,
                                       embedImages: embedImages, dropped: &book.droppedImages)
            book.chapters.append(body)
        }
        return book
    }

    /// Fonts may be "encrypted" with the IDPF or Adobe obfuscation algorithms, which only stop
    /// fonts being copied out; anything else (Adobe ADEPT, Apple FairPlay, …) is real DRM.
    static func isDRMProtected(_ archive: ArchiveEntries) throws -> Bool {
        if archive["META-INF/rights.xml"] != nil { return true }
        guard let data = archive["META-INF/encryption.xml"] else { return false }
        guard let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]) else { return true }
        let obfuscation: Set<String> = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
        let algorithms = try document.nodes(forXPath: "//*[local-name()='EncryptedData']/*[local-name()='EncryptionMethod']/@Algorithm")
            .compactMap(\.stringValue)
        return algorithms.contains { !obfuscation.contains($0) }
    }

    /// One chapter's body, cleaned: no scripts or external references, pictures inlined or removed,
    /// links within the book reduced to their #fragment.
    static func chapterBody(
        _ data: Data, path: String, archive: ArchiveEntries, types: [String: String],
        embedImages: Bool, dropped: inout Bool
    ) throws -> String {
        // Real XHTML parses strictly; tag-soup HTML (and XHTML that uses HTML entities without
        // their DTD) goes through the tidier instead.
        let document: XMLDocument
        if let strict = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]) {
            document = strict
        } else if let numeric = try? XMLDocument(data: XHTML.numericEntities(data), options: [.nodeLoadExternalEntitiesNever]) {
            document = numeric // XHTML using &nbsp; and friends without the DTD; tidying would lose SVG
        } else if let tidied = try? XMLDocument(data: data, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) {
            document = tidied
        } else {
            throw BookError.notABook("\(path) can't be read")
        }
        guard let body = try document.nodes(forXPath: "//*[local-name()='body']").first as? XMLElement else { return "" }
        XHTML.removeUnsafeContent(body)
        let directory = XHTML.directory(of: path)

        // SVG wrappers (common for covers) become plain images so the text engine can show them.
        for case let svg as XMLElement in try body.nodes(forXPath: ".//*[local-name()='svg']") {
            let image = (try? svg.nodes(forXPath: ".//*[local-name()='image']").first as? XMLElement) ?? nil
            let href = image?.attributes?.first { $0.localName == "href" }?.stringValue
            guard let href, let parent = svg.parent as? XMLElement else {
                svg.detach()
                dropped = dropped || embedImages
                continue
            }
            let img = XMLElement(name: "img")
            img.addAttribute(XMLNode.attribute(withName: "src", stringValue: href) as! XMLNode)
            parent.replaceChild(at: svg.index, with: img)
        }

        for case let img as XMLElement in try body.nodes(forXPath: ".//*[local-name()='img']") {
            let source = img.attribute(forName: "src")?.stringValue ?? ""
            guard embedImages, let imagePath = XHTML.resolve(source, from: directory), let bytes = archive[imagePath] else {
                img.detach()
                dropped = dropped || embedImages
                continue
            }
            let type = types[imagePath].flatMap { $0.hasPrefix("image/") ? $0 : nil } ?? XHTML.imageType(forPath: imagePath)
            img.attribute(forName: "src")?.stringValue = "data:\(type);base64,\(bytes.base64EncodedString())"
        }

        for case let link as XMLElement in try body.nodes(forXPath: ".//*[@href]") {
            guard let href = link.attribute(forName: "href")?.stringValue, !href.contains(":") else { continue }
            if let hash = href.firstIndex(of: "#") {
                link.attribute(forName: "href")?.stringValue = String(href[hash...])
            } else {
                link.removeAttribute(forName: "href")
            }
        }
        return (body.children ?? []).map(XHTML.serialize).joined()
    }

    static func combinedHTML(_ book: Book) -> String {
        let title = XHTML.escape(book.title ?? "Untitled")
        let author = book.authors.isEmpty ? "" : "<meta name=\"author\" content=\"\(XHTML.escape(book.authors.joined(separator: ", ")))\"/>\n"
        let language = XHTML.escape(book.language ?? "en")
        return """
        <!DOCTYPE html>
        <html lang="\(language)"><head><meta charset="utf-8"/><title>\(title)</title>
        \(author)<style>body { font-family: -apple-system, "Helvetica Neue", Helvetica, sans-serif; font-size: 12pt; line-height: 1.45; }</style>
        </head><body>
        \(book.chapters.joined(separator: "\n"))
        </body></html>
        """
    }

    /// Scales pictures down to the PDF text width and height; the text engine would otherwise clip them.
    static func fittingPictures(_ text: NSAttributedString) -> NSAttributedString {
        let maxWidth = PaginatedPDF.pageSize.width - 2 * PaginatedPDF.margin
        let maxHeight = PaginatedPDF.pageSize.height - 2 * PaginatedPDF.margin - 24
        let result = NSMutableAttributedString(attributedString: text)
        result.enumerateAttribute(.attachment, in: NSRange(location: 0, length: result.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let size = attachment.bounds.size != .zero
                ? attachment.bounds.size
                : (attachment.image?.size ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:))?.size ?? .zero)
            guard size.width > 0, size.height > 0 else { return }
            let scale = min(1, maxWidth / size.width, maxHeight / size.height)
            if scale < 1 {
                attachment.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
            }
        }
        return result
    }

    private static func parseXML(_ data: Data, part: String) throws -> XMLDocument {
        do {
            return try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        } catch {
            throw BookError.notABook("\(part) is damaged")
        }
    }
}
