import AmeyaCore
import AppKit
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AmeyaEngines

/// Untrusted documents and media must not pull other files on the Mac, or anything from the
/// network, into the output.
@Suite("External references", .serialized)
struct ExternalReferenceTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-refs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: HTML sanitizer

    @Test func sanitizerRemovesEverythingThatLoads() {
        let html = """
        <!DOCTYPE html><html><head><base href="file:///Users/"><link rel=stylesheet href="http://h/s.css">
        <meta http-equiv="refresh" content="0;url=file:///etc/passwd"><meta charset="utf-8">
        <style>@import url("http://h/i.css"); p { background: URL( 'file:///x.png' ) } q { b: url(data:image/png;base64,AA) }
        i { c: image-set("file:///a.png" 1x) } </style><script>alert(1)</script></head>
        <body onload="x()"><p class=a>Text &amp; more <a href="https://example.com/x">link</a> <a href="javascript:alert(1)">js</a>
        <a href="#top">top</a></p><img src="file:///Users/me/secret.png"><img src="&#102;ile:///Users/me/secret.png">
        <img src=" f\tile:///x"><img src="data:image/png;base64,iVBOR" alt=pic><img srcset="http://h/a.png 2x">
        <iframe src="http://h/f"></iframe><object data="file:///x"><embed src="file:///y"></object>
        <video poster="http://h/p.png"></video><table background="file:///t.png"><tr><td style="background:url(http://h/c)">c</td></tr></table>
        <svg><image href="file:///s.png"/><use xlink:href="file:///u.svg#a"/><style><img src="file:///in-style.png"></style></svg>
        <!-- <img src="file:///comment.png"> --> 1 < 2 <img src="file:///unterminated.png"
        """
        let (clean, removed) = HTMLSanitizer.sanitize(html)
        #expect(removed)
        for forbidden in ["file:", "http://h", "javascript:", "<script", "<iframe", "<object", "<embed", "<link", "<base",
                          "refresh", "onload", "@import", "srcset", "poster", "image-set", "alert", "comment.png"] {
            #expect(!clean.localizedCaseInsensitiveContains(forbidden), "\(forbidden) survived: \(clean)")
        }
        #expect(clean.contains("<!DOCTYPE html>"))
        #expect(clean.contains("Text &amp; more"))
        #expect(clean.contains(#"<a href="https://example.com/x">link</a>"#))
        #expect(clean.contains(##"<a href="#top">"##))
        #expect(clean.contains(#"src="data:image/png;base64,iVBOR""#))
        #expect(clean.contains("url(data:image/png;base64,AA)"))
        #expect(clean.contains("1 &lt; 2"))
        #expect(clean.contains(#"<td style="background:none">c</td>"#))
    }

    @Test func cssEscapesCantHideReferences() {
        let (escaped, removedEscaped) = HTMLSanitizer.sanitize(#"<p style="background: u\72l(file:///x.png)">a</p><style>q { quotes: "\201C" "\201D" }</style>"#)
        #expect(removedEscaped)
        #expect(!escaped.contains("72l"))
        #expect(escaped.contains(#"quotes: "\201C" "\201D""#))
        let (meta, removedMeta) = HTMLSanitizer.sanitize(#"<meta http-equiv="Content-Type" content="text/html; charset=utf-8"><meta name="author" content="A. Writer"/>"#, forWebKit: false)
        #expect(!removedMeta)
        #expect(meta == #"<meta name="author" content="A. Writer"/>"#)
    }

    @Test func sanitizerKeepsOrdinaryDocumentsIntact() {
        let html = "<html><body><h1 id=\"t\">Title</h1><p style=\"color: red\">Hello <b>world</b></p><ul><li>One</li></ul></body></html>"
        let (clean, removed) = HTMLSanitizer.sanitize(html, forWebKit: false)
        #expect(!removed)
        #expect(clean == "<html><body><h1 id=\"t\">Title</h1><p style=\"color: red\">Hello <b>world</b></p><ul><li>One</li></ul></body></html>")
    }

    @Test @MainActor func localPictureIsNotEmbeddedInDocuments() throws {
        let secret = directory.appendingPathComponent("secret.png")
        try Fixtures.encode([Fixtures.context(width: 40, height: 30).makeImage()!], as: .png).write(to: secret)
        let html = "<p>Hello</p><img src=\"\(secret.absoluteString)\"><img src=\"secret.png\"><div style=\"background:url(\(secret.absoluteString))\">x</div>"
        for target in [FileFormat.rtf, .docx, .pdf] {
            let (output, notes) = try DocumentConverter.convert(Data(html.utf8), from: .html, to: target)
            #expect(notes.contains(.externalResourcesSkipped), "\(target)")
            if target != .pdf {
                let text = try DocumentConverter.read(output, as: target)
                var attachments = 0
                text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                    if value != nil { attachments += 1 }
                }
                #expect(attachments == 0, "\(target)")
                #expect(text.string.contains("Hello"))
            }
        }
    }

    @Test @MainActor func noNetworkRequestsWhileReadingHTML() async throws {
        let listener = try LocalListener()
        let base = "http://127.0.0.1:\(listener.port)"
        let html = """
        <html><head><link rel="stylesheet" href="\(base)/link.css"><style>@import url("\(base)/import.css");
        p { background: url(\(base)/bg.png) }</style><script src="\(base)/s.js"></script></head>
        <body><p>Hello <a href="\(base)/anchor">link</a></p><img src="\(base)/img.png"><img srcset="\(base)/srcset.png 2x">
        <iframe src="\(base)/frame"></iframe><video poster="\(base)/poster.png"></video>
        <table background="\(base)/table.png"><tr><td style="background-image:url('\(base)/cell.png')">t</td></tr></table></body></html>
        """
        let markdown = "![picture](\(base)/md.png) and [a link](\(base)/md-link)"
        for target in [FileFormat.rtf, .docx, .pdf, .txt] {
            _ = try DocumentConverter.convert(Data(html.utf8), from: .html, to: target)
            _ = try DocumentConverter.convert(Data(markdown.utf8), from: .md, to: target)
        }
        try await Task.sleep(for: .seconds(1)) // let any late loads arrive
        #expect(listener.connections() == 0)
        // The listener does see connections: a control request reaches it.
        let control = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = listener.port.bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(control, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(connected == 0)
        close(control)
        #expect(listener.connections() == 1)
    }

    @Test @MainActor func markdownLeavesOutLocalPicturesAndScriptLinks() throws {
        let html = try MarkdownRenderer.html("![a](file:///etc/hosts) ![b](/abs/b.png) ![c](pics/c.png) [x](javascript:alert(1)) [y](https://e.com)")
        #expect(!html.contains("file:"))
        #expect(!html.contains("/abs/b.png"))
        #expect(!html.contains("javascript:"))
        #expect(html.contains(#"<img src="pics/c.png""#))
        #expect(html.contains(#"<a href="https://e.com">"#))
    }

    @Test @MainActor func booksMadeFromHTMLKeepNoOutsideLinks() throws {
        let html = "<html><head><style>body { background: url(file:///Users/me/bg.png) }</style></head><body><h1>T</h1><p style=\"background:url(http://h/x)\">Hi</p><img src=\"file:///Users/me/a.png\"></body></html>"
        let book = directory.appendingPathComponent("book.epub")
        let notes = try EbookWriter.write(Data(html.utf8), from: .html, to: book)
        #expect(notes.contains(.imagesDropped))
        let archive = try ArchiveEntries.read(book)
        for path in archive.paths {
            let text = String(decoding: archive[path] ?? Data(), as: UTF8.self)
            #expect(!text.contains("file:"), "\(path)")
            #expect(!text.contains("http://h"), "\(path)")
        }
    }

    // MARK: Media

    /// A QuickTime "reference movie": its track's samples stay in another file, by absolute path.
    func referenceMovie(to source: URL) async throws -> URL {
        let sourceAsset = AVURLAsset(url: source)
        let movie = AVMutableMovie()
        let duration = try await sourceAsset.load(.duration)
        try movie.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceAsset, at: .zero, copySampleData: false)
        let url = directory.appendingPathComponent("reference-\(UUID().uuidString).mov")
        try movie.writeHeader(to: url, fileType: .mov, options: .addMovieHeaderToDestination)
        return url
    }

    @Test func referenceMoviesAreRefused() async throws {
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let clip = try await Media.clip(in: outside, withAudio: true)
        let reference = try await referenceMovie(to: clip)
        let size = try FileManager.default.attributesOfItem(atPath: reference.path)[.size] as? Int ?? 0
        #expect(size < 20_000, "the movie should hold references, not samples")
        // Opened plainly, AVFoundation would follow the reference.
        #expect(try await AVURLAsset(url: reference).load(.isPlayable))

        // The reference restriction alone doesn't stop it; the self-containment check does.
        var refused = false
        do { _ = try await SafeAsset.open(reference) } catch { refused = true }
        #expect(refused)
        // A self-contained movie still opens.
        _ = try await SafeAsset.open(clip)
        var refusals = 0
        do { try await VideoConverter.transcode(input: reference, to: .mp4, output: directory.appendingPathComponent("out.mp4")) { _ in } } catch { refusals += 1 }
        do { try await AudioConverter.convert(input: reference, to: .wav, output: directory.appendingPathComponent("out.wav")) { _ in } } catch { refusals += 1 }
        do { _ = try await VideoConverter.toGIF(input: reference) { _ in } } catch { refusals += 1 }
        #expect(refusals == 3)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("out.mp4").path))
    }
}

/// A TCP socket on 127.0.0.1 that counts connection attempts without answering them.
final class LocalListener {
    private let socketDescriptor: Int32
    let port: UInt16

    init() throws {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(socketDescriptor, 64) == 0 else { throw CocoaError(.fileReadUnknown) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketDescriptor, $0, &length) }
        }
        _ = fcntl(socketDescriptor, F_SETFL, O_NONBLOCK)
        self.socketDescriptor = socketDescriptor
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { close(socketDescriptor) }

    /// Connections made so far.
    func connections() -> Int {
        var count = 0
        while true {
            let client = accept(socketDescriptor, nil, nil)
            guard client >= 0 else { return count }
            close(client)
            count += 1
        }
    }
}
