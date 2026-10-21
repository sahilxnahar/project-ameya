import AmeyaCore
import Foundation

/// Writes EPUB 3 books from Markdown, HTML, Word, RTF, OpenDocument and plain text.
///
/// The source becomes HTML, the system tidier turns that into a well-formed tree, and the
/// tree is split into chapters at each top-level h1/h2 heading. Every part is written as
/// XHTML by our own serializer, so the output is well-formed whatever the input looked like.
@MainActor
enum EbookWriter {
    static let defaultStyle = """
    body { font-family: serif; line-height: 1.5; margin: 0 1em; }
    h1, h2, h3, h4 { font-family: sans-serif; line-height: 1.25; }
    pre, code { font-family: monospace; font-size: 0.9em; }
    pre { white-space: pre-wrap; }
    blockquote { margin-left: 1em; padding-left: 1em; border-left: 3px solid #ccc; }
    table { border-collapse: collapse; }
    th, td { border: 1px solid #999; padding: 0.2em 0.5em; }
    img { max-width: 100%; }
    """

    struct Chapter {
        var title: String
        var body: String
    }

    static func write(_ data: Data, from source: FileFormat, to output: URL) throws -> [ConversionNote] {
        let raw: String = switch source {
        case .md: try MarkdownRenderer.html(DocumentConverter.decodeText(data))
        case .html: DocumentConverter.decodeHTML(data)
        default: String(decoding: try DocumentConverter.write(try DocumentConverter.read(data, as: source), as: .html), as: UTF8.self)
        }
        // References to outside files and web addresses (in tags, style attributes and style
        // sheets) never reach the book. Pictures that go are reported below as images dropped.
        let html = HTMLSanitizer.sanitize(raw, forWebKit: false).html
        guard let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let body = try document.nodes(forXPath: "//*[local-name()='body']").first as? XMLElement else {
            throw ConversionError.unreadable
        }

        // Styles from HTML and the system writer (Word, RTF, …) carry fonts and spacing; Markdown has none worth keeping.
        var style = defaultStyle
        if source != .md {
            style += "\n" + (try document.nodes(forXPath: "//*[local-name()='head']/*[local-name()='style']"))
                .compactMap(\.stringValue).joined(separator: "\n")
        }
        XHTML.removeUnsafeContent(body)

        var notes: [ConversionNote] = ConversionMatrix(writable: [.epub]).possibleLosses(from: source, to: .epub)
        var images: [(path: String, type: String, data: Data)] = []
        for case let img as XMLElement in try body.nodes(forXPath: ".//*[local-name()='img']") {
            guard let source = img.attribute(forName: "src")?.stringValue,
                  let (type, bytes) = XHTML.decodeDataURL(source),
                  let ext = XHTML.imageExtensions[type] else {
                img.detach()
                if !notes.contains(.imagesDropped) { notes.append(.imagesDropped) }
                continue
            }
            let path = "images/image-\(images.count + 1).\(ext)"
            images.append((path, type, bytes))
            img.attribute(forName: "src")?.stringValue = path
            if img.attribute(forName: "alt") == nil {
                img.addAttribute(XMLNode.attribute(withName: "alt", stringValue: "") as! XMLNode)
            }
        }

        let language = (document.rootElement()?.attribute(forName: "lang")?.stringValue).flatMap { $0.isEmpty ? nil : $0 } ?? "en"
        let title = bookTitle(document: document, body: body)
        let chapters = split(contentNodes(of: body), bookTitle: title)
        try package(title: title, language: language, style: style, chapters: chapters, images: images, to: output)
        return notes
    }

    /// The nodes to split into chapters. A single wrapper (a <div>, <main>, <article> or
    /// <section> holding everything) is looked through, so its headings can start chapters.
    static func contentNodes(of body: XMLElement) -> [XMLNode] {
        var nodes = body.children ?? []
        while true {
            let significant = nodes.filter(XHTML.hasContent)
            guard significant.count == 1, let wrapper = significant[0] as? XMLElement,
                  ["div", "main", "article", "section"].contains(wrapper.localName ?? "") else { return nodes }
            nodes = wrapper.children ?? []
        }
    }

    /// Starts a chapter at every h1 and h2, except that a chapter holding only headings so far
    /// (a book title followed by a first section, say) absorbs the next one.
    static func split(_ nodes: [XMLNode], bookTitle: String) -> [Chapter] {
        var groups: [[XMLNode]] = [[]]
        for node in nodes {
            let current = groups[groups.count - 1]
            let onlyHeadings = current.filter(XHTML.hasContent).allSatisfy { XHTML.headingLevel($0) != nil }
            if let level = XHTML.headingLevel(node), level <= 2, !onlyHeadings {
                groups.append([node])
            } else {
                groups[groups.count - 1].append(node)
            }
        }
        let filled = groups.filter { $0.contains(where: XHTML.hasContent) }
        if filled.isEmpty { return [Chapter(title: bookTitle, body: "<p></p>")] }
        return filled.enumerated().map { index, group in
            let heading = group.first { XHTML.headingLevel($0) != nil }.flatMap { XHTML.text(of: $0) }
            let title = heading ?? (filled.count == 1 ? bookTitle : "Chapter \(index + 1)")
            return Chapter(title: title, body: group.map(XHTML.serialize).joined())
        }
    }

    /// The first heading, else a meaningful <title>, else the first line of text.
    static func bookTitle(document: XMLDocument, body: XMLElement) -> String {
        for level in 1...6 {
            if let heading = try? body.nodes(forXPath: ".//*[local-name()='h\(level)']").first, let text = XHTML.text(of: heading) {
                return text
            }
        }
        if let title = (try? document.nodes(forXPath: "//*[local-name()='head']/*[local-name()='title']"))?.first.flatMap(XHTML.text(of:)),
           title != "Document" {
            return title
        }
        let firstLine = (body.stringValue ?? "").split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return firstLine.map { String($0.prefix(80)) } ?? "Untitled"
    }

    static func package(
        title: String, language: String, style: String, chapters: [Chapter],
        images: [(path: String, type: String, data: Data)], to output: URL
    ) throws {
        let lang = XHTML.escape(language)
        let names = chapters.indices.map { String(format: "chapter-%03d.xhtml", $0 + 1) }
        let modified = ISO8601DateFormatter().string(from: Date())

        var manifest = """
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="style" href="style.css" media-type="text/css"/>\n
        """
        for name in names {
            manifest += "<item id=\"\(name.dropLast(6))\" href=\"\(name)\" media-type=\"application/xhtml+xml\"/>\n"
        }
        for (index, image) in images.enumerated() {
            manifest += "<item id=\"image-\(index + 1)\" href=\"\(image.path)\" media-type=\"\(image.type)\"/>\n"
        }
        let spine = names.map { "<itemref idref=\"\($0.dropLast(6))\"/>" }.joined(separator: "\n")
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" xml:lang="\(lang)">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="book-id">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>
        <dc:title>\(XHTML.escape(title))</dc:title>
        <dc:language>\(lang)</dc:language>
        <meta property="dcterms:modified">\(modified)</meta>
        </metadata>
        <manifest>
        \(manifest)</manifest>
        <spine>
        \(spine)
        </spine>
        </package>
        """
        let links = zip(names, chapters).map { "<li><a href=\"\($0)\">\(XHTML.escape($1.title))</a></li>" }.joined(separator: "\n")
        let nav = page(title: "Contents", language: lang, stylesheet: false, body: """
        <nav epub:type="toc" id="toc"><h1>Contents</h1>
        <ol>
        \(links)
        </ol></nav>
        """)
        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """

        var archive = try ZipWriter(url: output)
        try archive.add("mimetype", Data("application/epub+zip".utf8), method: .store) // must be first and stored
        try archive.add("META-INF/container.xml", Data(container.utf8))
        try archive.add("OEBPS/content.opf", Data(opf.utf8))
        try archive.add("OEBPS/nav.xhtml", Data(nav.utf8))
        try archive.add("OEBPS/style.css", Data(style.utf8))
        for (name, chapter) in zip(names, chapters) {
            let xhtml = page(title: chapter.title, language: lang, stylesheet: true, body: chapter.body)
            try archive.add("OEBPS/\(name)", Data(xhtml.utf8))
        }
        for image in images {
            try archive.add("OEBPS/\(image.path)", image.data, method: .store) // already compressed
        }
        try archive.finish()
    }

    static func page(title: String, language: String, stylesheet: Bool, body: String) -> String {
        let link = stylesheet ? "\n<link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/>" : ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(language)" lang="\(language)">
        <head><meta charset="UTF-8"/><title>\(XHTML.escape(title))</title>\(link)</head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}
