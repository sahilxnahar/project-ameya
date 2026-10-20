import AmeyaCore
import Foundation
import PDFKit
import Testing
@testable import AmeyaEngines

@Suite("Archives", .serialized)
struct ArchiveTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("content/sub"), withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: directory.appendingPathComponent("content/a.txt"))
        try Data("beta in a folder".utf8).write(to: directory.appendingPathComponent("content/sub/b.txt"))
    }

    @Test("A ZIP repacks into every writable archive format", arguments: [FileFormat.tar, .tgz, .tbz2, .txz, .sevenZip, .zip])
    func repackEverywhere(target: FileFormat) throws {
        let zip = try bsdtar(["-a", "-cf", "source.zip", "-C", "content", "a.txt", "sub"])
        let output = directory.appendingPathComponent("out.\(target.preferredExtension)")
        let notes = try ArchiveConverter.repack(input: zip, to: target, output: output) { _ in }
        #expect(notes.isEmpty)
        #expect(FileFormat.detect(at: output) == (target == .tar ? .tar : target))
        let listing = try run("/usr/bin/tar", ["-tf", output.path])
        #expect(listing.contains("a.txt"))
        #expect(listing.contains("sub/b.txt"))
        #expect(try run("/usr/bin/tar", ["-xOf", output.path, "sub/b.txt"]) == "beta in a folder")
    }

    @Test func unsafePathsAndEscapingLinksAreLeftOut() throws {
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("content/escape").path,
                                                   withDestinationPath: "../../../etc/passwd")
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("content/inside").path,
                                                   withDestinationPath: "sub/b.txt")
        // Rewrite a.txt's name to climb out of the extraction folder.
        let evil = try bsdtar(["-cf", "evil.tar", "-s", ",^a.txt$,../../a.txt,", "-C", "content", "a.txt", "sub", "escape", "inside"])
        let output = directory.appendingPathComponent("clean.zip")
        let notes = try ArchiveConverter.repack(input: evil, to: .zip, output: output) { _ in }
        #expect(notes == [.specialFilesSkipped, .unsafeEntriesSkipped])
        let listing = try run("/usr/bin/tar", ["-tf", output.path])
        #expect(!listing.contains(".."))
        #expect(!listing.contains("escape"))
        #expect(listing.contains("inside"))
        #expect(listing.contains("sub/b.txt"))
    }

    @Test func sizeLimitsStopZipBombs() throws {
        try Data(count: 2 << 20).write(to: directory.appendingPathComponent("content/zeros.bin"))
        let zip = try bsdtar(["-a", "-cf", "bomb.zip", "-C", "content", "zeros.bin"])
        var limits = ArchiveConverter.Limits()
        limits.maxTotalBytes = 1 << 20
        #expect(throws: ConversionError.self) {
            try ArchiveConverter.repack(input: zip, to: .tar, output: directory.appendingPathComponent("bomb.tar"), limits: limits) { _ in }
        }
    }

    @Test func garbageIsNotAnArchive() throws {
        let garbage = directory.appendingPathComponent("garbage.zip")
        try Data("not really a zip file".utf8).write(to: garbage)
        #expect(throws: ConversionError.self) {
            try ArchiveConverter.repack(input: garbage, to: .tar, output: directory.appendingPathComponent("g.tar")) { _ in }
        }
    }

    @Test func pathRules() {
        #expect(ArchiveConverter.safePath("a/b.txt") == "a/b.txt")
        #expect(ArchiveConverter.safePath("./a//b/") == "a/b/")
        #expect(ArchiveConverter.safePath("../a") == nil)
        #expect(ArchiveConverter.safePath("a/../../b") == nil)
        #expect(ArchiveConverter.safePath("/etc/passwd") == nil)
        #expect(ArchiveConverter.safePath("") == nil)
        #expect(ArchiveConverter.linkStaysInside("b.txt", from: "dir/link"))
        #expect(ArchiveConverter.linkStaysInside("../b.txt", from: "dir/link"))
        #expect(!ArchiveConverter.linkStaysInside("../../b.txt", from: "dir/link"))
        #expect(!ArchiveConverter.linkStaysInside("/etc/passwd", from: "link"))
    }

    // MARK: Helpers

    private func bsdtar(_ arguments: [String]) throws -> URL {
        _ = try run("/usr/bin/tar", arguments)
        return directory.appendingPathComponent(arguments[arguments.firstIndex(of: "-cf")! + 1])
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        return String(decoding: output, as: UTF8.self)
    }
}

@Suite("Markdown")
@MainActor
struct MarkdownTests {
    let markdown = """
    # Release notes

    Some **bold**, some *italic*, `inline code` and a [link](https://example.com).

    - first
    - second

    1. one
    2. two

    ```swift
    let x = 1 < 2
    ```

    | Name | Size |
    | --- | --- |
    | a.txt | 5 |

    > Quoted
    """

    @Test func rendersSemanticHTML() throws {
        let html = try MarkdownRenderer.html(markdown)
        for fragment in ["<h1>Release notes</h1>", "<strong>bold</strong>", "<em>italic</em>", "<code>inline code</code>",
                         "<a href=\"https://example.com\">link</a>", "<ul>", "<li>", "<ol>",
                         "<pre><code class=\"language-swift\">let x = 1 &lt; 2", "<th>Name</th>", "<td>a.txt</td>", "<blockquote>"] {
            #expect(html.contains(fragment), "missing \(fragment)")
        }
    }

    @Test func markdownToHTMLGoesStraightThrough() throws {
        let (data, notes) = try DocumentConverter.convert(Data(markdown.utf8), from: .md, to: .html)
        #expect(String(decoding: data, as: UTF8.self).contains("<h1>Release notes</h1>"))
        #expect(notes.isEmpty)
    }

    @Test func survivesARoundTripThroughWord() throws {
        let (docx, _) = try DocumentConverter.convert(Data(markdown.utf8), from: .md, to: .docx)
        let (back, notes) = try DocumentConverter.convert(docx, from: .docx, to: .md)
        let text = String(decoding: back, as: UTF8.self)
        #expect(notes == [.markdownSimplified])
        #expect(text.contains("# Release notes"))
        #expect(text.contains("**bold**"))
        #expect(text.contains("*italic*"))
        #expect(text.contains("- first"))
        #expect(text.contains("2. two"))
        // Apple's DOCX writer drops hyperlinks; our own DOCX writer (roadmap) will keep them.
    }

    @Test func survivesARoundTripThroughHTML() throws {
        let (html, _) = try DocumentConverter.convert(Data(markdown.utf8), from: .md, to: .html)
        let (back, _) = try DocumentConverter.convert(html, from: .html, to: .md)
        let text = String(decoding: back, as: UTF8.self)
        #expect(text.contains("# Release notes"))
        #expect(text.contains("- second"))
        #expect(text.contains("1. one"))
        #expect(text.contains("[link](https://example.com"), "\(text)")
        #expect(text.contains("| Name | Size |"), "\(text)")
        #expect(text.contains("let x = 1 < 2"))
    }

    @Test func htmlTablesBecomeMarkdownTables() throws {
        let html = "<html><body><table><tr><td>a</td><td>b</td></tr><tr><td>1</td><td>2</td></tr></table></body></html>"
        let (md, _) = try DocumentConverter.convert(Data(html.utf8), from: .html, to: .md)
        let text = String(decoding: md, as: UTF8.self)
        #expect(text.contains("| a | b |"))
        #expect(text.contains("| 1 | 2 |"))
    }

    @Test func rendersToPDF() throws {
        let (pdf, _) = try DocumentConverter.convert(Data(markdown.utf8), from: .md, to: .pdf)
        let text = try #require(PDFDocument(data: pdf)?.string)
        #expect(text.contains("Release notes"))
        #expect(text.contains("second"))
    }
}
