import AmeyaCore
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import AmeyaEngines

@Suite("E-books", .serialized)
@MainActor
struct EbookTests {
    let directory: URL
    let markdown = """
    # The Test Book

    An opening line with an ampersand & a <tag>.

    ## Chapter One

    Alpha text lives here.

    ## Chapter Two

    Beta text, with *emphasis* and a [link](https://example.com).

    ## Chapter Three

    Gamma text closes the book.
    """

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-ebook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func makeEPUB(from text: String, as source: FileFormat = .md, name: String = "book.epub") throws -> (URL, [ConversionNote]) {
        let url = directory.appendingPathComponent(name)
        let notes = try EbookWriter.write(Data(text.utf8), from: source, to: url)
        return (url, notes)
    }

    /// A hand-built EPUB, for books whose insides the tests need to control.
    private func zipBook(_ files: [(String, String)], name: String = "hand.epub") throws -> URL {
        let url = directory.appendingPathComponent(name)
        var zip = try ZipWriter(url: url)
        try zip.add("mimetype", Data("application/epub+zip".utf8), method: .store)
        for (path, content) in files { try zip.add(path, Data(content.utf8)) }
        try zip.finish()
        return url
    }

    private let container = """
    <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
    """

    private func opf(spine: [(id: String, href: String)], extra: String = "") -> String {
        """
        <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Hand Made</dc:title><dc:creator>A. Writer</dc:creator>
        <dc:language>en</dc:language></metadata><manifest>
        \(spine.map { "<item id=\"\($0.id)\" href=\"\($0.href)\" media-type=\"application/xhtml+xml\"/>" }.joined())
        \(extra)</manifest><spine>\(spine.map { "<itemref idref=\"\($0.id)\"/>" }.joined())</spine></package>
        """
    }

    @Test func markdownBecomesAWellFormedEPUB() throws {
        let (url, notes) = try makeEPUB(from: markdown)
        #expect(notes.isEmpty)
        let bytes = [UInt8](try Data(contentsOf: url))
        // OCF: `mimetype` first, stored (method 0), no extra field, so the type sits at byte 38.
        #expect(bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]))
        #expect(bytes[8] == 0 && bytes[9] == 0)
        #expect(bytes[28] == 0 && bytes[29] == 0)
        #expect(String(decoding: bytes[30..<38], as: UTF8.self) == "mimetype")
        #expect(String(decoding: bytes[38..<58], as: UTF8.self) == "application/epub+zip")
        #expect(FileFormat.detect(at: url) == .epub)
        _ = try run("/usr/bin/unzip", ["-tq", url.path]) // CRCs and structure check out

        let archive = try ArchiveEntries.read(url)
        #expect(archive.paths.first == "mimetype")
        for part in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/style.css"] {
            #expect(archive[part] != nil, "missing \(part)")
        }
        let chapters = archive.paths.filter { $0.hasPrefix("OEBPS/chapter-") }
        #expect(chapters.count == 4) // the title with its opening line, then one per section
        for path in archive.paths where [".xhtml", ".opf", ".xml"].contains(where: path.hasSuffix) {
            let parser = XMLParser(data: archive[path]!)
            parser.shouldProcessNamespaces = true
            #expect(parser.parse(), "\(path) is not well-formed: \(String(describing: parser.parserError))")
        }

        let opf = String(decoding: archive["OEBPS/content.opf"]!, as: UTF8.self)
        #expect(opf.contains("<dc:identifier id=\"book-id\">urn:uuid:"))
        #expect(opf.contains("<dc:title>The Test Book</dc:title>"))
        #expect(opf.contains("<dc:language>en</dc:language>"))
        #expect(opf.contains("property=\"dcterms:modified\""))
        #expect(opf.contains("properties=\"nav\""))
        let nav = String(decoding: archive["OEBPS/nav.xhtml"]!, as: UTF8.self)
        #expect(nav.contains("epub:type=\"toc\""))
        #expect(nav.contains(">Chapter Two</a>"))
        let first = String(decoding: archive["OEBPS/chapter-001.xhtml"]!, as: UTF8.self)
        #expect(first.contains("&amp; a &lt;tag&gt;"))
    }

    @Test("Markdown → EPUB → text keeps every chapter in order", arguments: [FileFormat.md, .txt, .html, .docx])
    func roundTrip(to target: FileFormat) throws {
        let (url, _) = try makeEPUB(from: markdown)
        let (data, notes) = try EbookConverter.convert(input: url, to: target)
        let text: String = if target == .docx {
            try DocumentConverter.read(data, as: .docx).string
        } else {
            String(decoding: data, as: UTF8.self)
        }
        let markers = ["The Test Book", "Chapter One", "Alpha text", "Chapter Two", "Beta text", "Chapter Three", "Gamma text"]
        let positions = try markers.map { marker in try #require(text.range(of: marker), "\(marker) missing").lowerBound }
        #expect(positions == positions.sorted())
        if target == .md { #expect(text.contains("## Chapter Two")) }
        if target == .html { #expect(!text.contains("<script")) }
        #expect(!notes.contains(.imagesDropped))
    }

    @Test func epubRendersToPDFWithText() throws {
        let (url, _) = try makeEPUB(from: markdown)
        let (pdf, notes) = try EbookConverter.convert(input: url, to: .pdf)
        let document = try #require(PDFDocument(data: pdf))
        let text = document.string ?? ""
        #expect(text.contains("Alpha text lives here."))
        #expect(text.contains("Gamma text closes the book."))
        #expect(notes == [.bookLayoutReflowed])
    }

    @Test func engineRoutesBothDirections() async throws {
        let source = directory.appendingPathComponent("in.md")
        try Data(markdown.utf8).write(to: source)
        let (epub, _) = try await Engine.convert(input: source, request: ConversionRequest(source: .md, target: .epub), scratch: directory) { _ in }
        #expect(FileFormat.detect(at: epub) == .epub)
        let scratch = directory.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let (pdf, result) = try await Engine.convert(input: epub, request: ConversionRequest(source: .epub, target: .pdf), scratch: scratch) { _ in }
        #expect(FileFormat.detect(at: pdf) == .pdf)
        #expect(result.notes == [.bookLayoutReflowed])
    }

    @Test func readerCleansChaptersAndInlinesPictures() throws {
        let png = try Fixtures.encode(Fixtures.frames(1), as: .png)
        let chapter = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>c</title><script>alert(1)</script></head><body>
        <h1 onclick="steal()">Opening&nbsp;Scene</h1><script>alert(2)</script>
        <p>See <a href="two.xhtml#end">later</a> or <a href="javascript:evil()">this</a>.</p>
        <p><img src="../Images/pic.png" alt="pic"/><img src="missing.png"/></p>
        <svg xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="../Images/pic.png"/></svg>
        </body></html>
        """
        let url = directory.appendingPathComponent("pictures.epub")
        var zip = try ZipWriter(url: url)
        try zip.add("mimetype", Data("application/epub+zip".utf8), method: .store)
        try zip.add("META-INF/container.xml", Data(container.utf8))
        try zip.add("OPS/book.opf", Data(opf(spine: [("c1", "Text/one.xhtml"), ("c2", "Text/two.xhtml")],
                                             extra: "<item id=\"p\" href=\"Images/pic.png\" media-type=\"image/png\"/>").utf8))
        try zip.add("OPS/Text/one.xhtml", Data(chapter.utf8))
        try zip.add("OPS/Text/two.xhtml", Data("<html><body><p id=\"end\">The end.</p></body></html>".utf8))
        try zip.add("OPS/Images/pic.png", png, method: .store)
        try zip.finish()

        let book = try EbookConverter.read(url)
        #expect(book.title == "Hand Made")
        #expect(book.authors == ["A. Writer"])
        #expect(book.chapters.count == 2)
        #expect(book.droppedImages)
        let (data, notes) = try EbookConverter.convert(input: url, to: .html)
        let html = String(decoding: data, as: UTF8.self)
        #expect(!html.contains("<script") && !html.contains("alert(") && !html.contains("onclick") && !html.contains("javascript:"))
        #expect(html.components(separatedBy: "data:image/png;base64,").count == 3) // the <img> and the SVG cover
        #expect(html.contains("href=\"#end\""))
        #expect(html.contains("Opening\u{A0}Scene"))
        #expect(html.contains("<meta name=\"author\" content=\"A. Writer\"/>"))
        #expect(notes.contains(.imagesDropped))
        // Pictures reach rich text as attachments.
        let rich = try DocumentConverter.read(data, as: .html)
        var attachments = 0
        rich.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        #expect(attachments >= 1)
    }

    @Test func htmlPicturesAndWordDocumentsBecomeEPUBs() throws {
        let png = try Fixtures.encode(Fixtures.frames(1), as: .png).base64EncodedString()
        let html = "<html><body><div><h1>Pictures</h1><p>One <img src=\"data:image/png;base64,\(png)\"> <img src=\"remote.png\"></p><h2>Next</h2><p>More<br>lines</p></div></body></html>"
        let (url, notes) = try makeEPUB(from: html, as: .html, name: "pictures.epub")
        #expect(notes == [.imagesDropped])
        let archive = try ArchiveEntries.read(url)
        #expect(archive["OEBPS/images/image-1.png"] != nil)
        #expect(String(decoding: archive["OEBPS/content.opf"]!, as: UTF8.self).contains("href=\"images/image-1.png\" media-type=\"image/png\""))
        #expect(archive.paths.filter { $0.hasPrefix("OEBPS/chapter-") }.count == 2) // split inside the wrapper <div>
        #expect(String(decoding: archive["OEBPS/chapter-002.xhtml"]!, as: UTF8.self).contains("More<br/>lines"))

        let (_, plainNotes) = try makeEPUB(from: "Plain title\nPlain body.", as: .txt, name: "plain.epub")
        #expect(plainNotes.isEmpty)

        let (docx, _) = try DocumentConverter.convert(Data("Memo title\nBody of the memo.".utf8), from: .txt, to: .docx)
        let docxURL = directory.appendingPathComponent("memo.epub")
        let docxNotes = try EbookWriter.write(docx, from: .docx, to: docxURL)
        #expect(docxNotes == [.bookLayoutReflowed])
        let (text, _) = try EbookConverter.convert(input: docxURL, to: .txt)
        #expect(String(decoding: text, as: UTF8.self).contains("Body of the memo."))
        let opf = String(decoding: try ArchiveEntries.read(docxURL)["OEBPS/content.opf"]!, as: UTF8.self)
        #expect(opf.contains("<dc:title>Memo title</dc:title>"))
    }

    @Test func drmProtectedBooksAreRefused() throws {
        let encryption = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
        <enc:EncryptedData><enc:EncryptionMethod Algorithm="%@"/><enc:CipherData><enc:CipherReference URI="OPS/one.xhtml"/></enc:CipherData></enc:EncryptedData>
        </encryption>
        """
        let files = [("META-INF/container.xml", container), ("OPS/book.opf", opf(spine: [("c1", "one.xhtml")])),
                     ("OPS/one.xhtml", "<html><body><p>Secret</p></body></html>")]
        let locked = try zipBook(files + [("META-INF/encryption.xml", String(format: encryption, "http://www.w3.org/2001/04/xmlenc#aes128-cbc"))], name: "drm.epub")
        #expect(throws: BookError.drmProtected) { try EbookConverter.read(locked) }
        #expect(BookError.drmProtected.errorDescription?.contains("DRM-protected") == true)
        // Font obfuscation is not DRM.
        let fonts = try zipBook(files + [("META-INF/encryption.xml", String(format: encryption, "http://www.idpf.org/2008/embedding"))], name: "fonts.epub")
        #expect(try EbookConverter.read(fonts).chapters.count == 1)
    }

    @Test func brokenAndHostileBooksAreRejected() throws {
        let garbage = directory.appendingPathComponent("garbage.epub")
        try Data("this is not a zip file at all".utf8).write(to: garbage)
        #expect(throws: ConversionError.unreadable) { try EbookConverter.read(garbage) }

        let noContainer = try zipBook([("OPS/one.xhtml", "<p>x</p>")], name: "nocontainer.epub")
        #expect(throws: BookError.notABook("META-INF/container.xml is missing")) { try EbookConverter.read(noContainer) }

        let traversal = try zipBook([("META-INF/container.xml", container), ("OPS/book.opf", opf(spine: [("c1", "../../../etc/passwd")]))], name: "escape.epub")
        #expect(throws: BookError.notABook("it has no chapters")) { try EbookConverter.read(traversal) }

        let missing = try zipBook([("META-INF/container.xml", container), ("OPS/book.opf", opf(spine: [("c1", "gone.xhtml")]))], name: "missing.epub")
        #expect(throws: BookError.missingPart("OPS/gone.xhtml")) { try EbookConverter.read(missing) }

        let badOPF = try zipBook([("META-INF/container.xml", container), ("OPS/book.opf", "<package><unclosed>")], name: "badopf.epub")
        #expect(throws: BookError.notABook("OPS/book.opf is damaged")) { try EbookConverter.read(badOPF) }

        let big = try zipBook([("META-INF/container.xml", container), ("OPS/big.bin", String(repeating: "x", count: 2 << 20))], name: "big.epub")
        #expect(throws: BookError.tooLarge(megabytes: 1)) {
            try ArchiveEntries.read(big, limits: ArchiveEntries.Limits(maxEntries: 100, maxTotalBytes: 1 << 20))
        }
    }

    @Test func hrefsCannotLeaveTheBook() {
        #expect(XHTML.resolve("Text/ch%201.xhtml#p3", from: "OPS") == "OPS/Text/ch 1.xhtml")
        #expect(XHTML.resolve("../Images/a.png", from: "OPS/Text") == "OPS/Images/a.png")
        #expect(XHTML.resolve("../../a.png", from: "OPS") == nil)
        #expect(XHTML.resolve("/etc/passwd", from: "OPS") == nil)
        #expect(XHTML.resolve("http://example.com/a.png", from: "OPS") == nil)
        #expect(XHTML.resolve("#note", from: "OPS") == nil)
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return String(decoding: output, as: UTF8.self)
    }
}

@Suite("Comics", .serialized)
struct ComicTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-comic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A picture whose width identifies it, so page order can be read back from the PDF.
    private func picture(width: Int, as format: FileFormat) throws -> Data {
        try Fixtures.encode([Fixtures.context(width: width, height: 40).makeImage()!], as: format)
    }

    private func comic(_ entries: [(String, Data)], name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var zip = try ZipWriter(url: url)
        for (path, data) in entries { try zip.add(path, data) }
        try zip.finish()
        return url
    }

    @Test func pagesFollowNaturalReadingOrder() throws {
        let url = try comic([
            ("10.jpg", try picture(width: 100, as: .jpeg)),
            ("2.jpg", try picture(width: 20, as: .jpeg)),
            ("__MACOSX/._2.jpg", Data("resource fork".utf8)),
            (".hidden.png", try picture(width: 5, as: .png)),
            ("1.png", try picture(width: 10, as: .png)),
            ("ComicInfo.xml", Data("<ComicInfo/>".utf8)),
        ], name: "order.cbz")
        #expect(FileFormat.detect(at: url) == .cbz)
        let output = directory.appendingPathComponent("order.pdf")
        let (notes, frames) = try ComicConverter.toPDF(input: url, output: output, options: ConversionOptions()) { _ in }
        #expect(notes.isEmpty) // junk and ComicInfo.xml are left out quietly
        #expect(frames == 3)
        let document = try #require(CGPDFDocument(output as CFURL))
        let widths = (1...document.numberOfPages).map { Int(document.page(at: $0)!.getBoxRect(.mediaBox).width.rounded()) }
        #expect(widths == [10, 20, 100])
    }

    @Test func otherFilesAreReportedAndEmptyComicsRejected() throws {
        let url = try comic([("001.jpg", try picture(width: 30, as: .jpeg)), ("readme.txt", Data("hi".utf8))], name: "notes.cbr")
        let (notes, _) = try ComicConverter.toPDF(input: url, output: directory.appendingPathComponent("n.pdf"), options: ConversionOptions()) { _ in }
        #expect(notes == [.nonImagesSkipped])

        let repacked = directory.appendingPathComponent("repacked.cbz")
        let (_, frames) = try ComicConverter.repack(input: url, output: repacked, options: ConversionOptions()) { _ in }
        #expect(frames == 1)
        #expect(try ArchiveEntries.read(repacked).paths == ["001.jpg"])

        let empty = try comic([("readme.txt", Data("no pictures".utf8))], name: "empty.cbz")
        #expect(throws: BookError.noPages) {
            try ComicConverter.toPDF(input: empty, output: directory.appendingPathComponent("e.pdf"), options: ConversionOptions()) { _ in }
        }
        let garbage = directory.appendingPathComponent("garbage.cbz")
        try Data("PK but not really".utf8).write(to: garbage)
        #expect(throws: ConversionError.unreadable) {
            try ComicConverter.toPDF(input: garbage, output: directory.appendingPathComponent("g.pdf"), options: ConversionOptions()) { _ in }
        }
        var limited = ConversionOptions()
        limited.maxFrames = 0
        #expect(throws: BookError.tooManyPages(limit: 0)) {
            try ComicConverter.toPDF(input: url, output: directory.appendingPathComponent("l.pdf"), options: limited) { _ in }
        }
    }

    @Test func pdfPagesBecomeNumberedJPEGs() throws {
        let frames = Fixtures.frames(3).map { DecodedFrame(image: $0, delay: nil, metadata: [:]) }
        let pdf = directory.appendingPathComponent("pages.pdf")
        try PDFWriter.write(frames).write(to: pdf)
        let output = directory.appendingPathComponent("pages.cbz")
        let (notes, count) = try ComicConverter.fromPDF(input: pdf, output: output, options: ConversionOptions()) { _ in }
        #expect(notes == [.pagesBecamePictures])
        #expect(count == 3)
        #expect(FileFormat.detect(at: output) == .cbz)
        let archive = try ArchiveEntries.read(output)
        #expect(archive.paths == ["001.jpg", "002.jpg", "003.jpg"])
        for path in archive.paths {
            #expect(FileFormat.sniff(archive[path]!) == .jpeg)
        }
        // And back again: the round trip keeps the page count.
        let back = directory.appendingPathComponent("back.pdf")
        let (_, pages) = try ComicConverter.toPDF(input: output, output: back, options: ConversionOptions()) { _ in }
        #expect(pages == 3)
    }

    @Test func zipWriterOutputIsReadableByOtherTools() throws {
        let text = Data(String(repeating: "compressible text ", count: 500).utf8)
        let url = try comic([("a.txt", text), ("dir/ünï.txt", Data("utf8 name".utf8))], name: "check.zip")
        #expect(try ArchiveEntries.read(url)["a.txt"] == text)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tq", url.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}
