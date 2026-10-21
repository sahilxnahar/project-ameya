import AmeyaCore
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import AmeyaEngines

/// Scans made in memory: text drawn into a bitmap, so the PDF has no text layer.
enum ScanFixtures {
    static let lines = ["Invoice number 4821", "Ameya reads scanned pages", "Total due 129 rupees"]

    /// White page image (200 dpi US Letter) with `lines` in black, top to bottom.
    static func image(_ lines: [String] = lines, width: Int = 1700, height: Int = 2200, fontSize: CGFloat = 56) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        for (index, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]))
            context.textPosition = CGPoint(x: 150, y: CGFloat(height) - 250 - CGFloat(index) * fontSize * 2.2)
            CTLineDraw(line, context)
        }
        return context.makeImage()!
    }

    /// A PDF whose pages are `pages`: an image, or real (vector) text.
    enum Page { case scan([String]), text(String) }

    static func pdf(_ pages: [Page]) -> Data {
        let data = NSMutableData()
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: nil, nil)!
        for page in pages {
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            context.beginPage(mediaBox: &box)
            switch page {
            case .scan(let lines):
                context.draw(image(lines), in: box)
            case .text(let text):
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 14, nil),
                ]))
                context.textPosition = CGPoint(x: 72, y: 700)
                CTLineDraw(line, context)
            }
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }

    /// Mean absolute difference per channel (0…255) between two renders of the same size.
    static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return 255 }
        func pixels(_ image: CGImage) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
            buffer.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return buffer
        }
        let (x, y) = (pixels(a), pixels(b))
        let total = zip(x, y).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(x.count)
    }
}

@Suite("Text recognition and PDF toolbox")
@MainActor
struct PDFOCRTests {
    let scratch: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-ocr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func run(_ action: AmeyaCore.PDFAction, _ input: URL, from source: FileFormat = .pdf,
                     to target: FileFormat = .pdf) async throws -> (output: URL, result: ConversionResult) {
        let work = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let request = ConversionRequest(source: source, target: target, options: ConversionOptions(pdf: action))
        let (outputs, result) = try await Engine.run(inputs: [input], request: request, scratch: work) { _ in }
        return (outputs[0], result)
    }

    private func text(of url: URL, page: Int = 0) -> String {
        PDFDocument(url: url)?.page(at: page)?.string ?? ""
    }

    // MARK: Searchable PDF

    @Test func scannedPageBecomesSearchableInReadingOrderAndLooksTheSame() async throws {
        let input = try file("scan.pdf", ScanFixtures.pdf([.scan(ScanFixtures.lines)]))
        #expect(text(of: input).isEmpty)
        let (output, result) = try await run(.ocr(languages: ["en-US"]), input)
        #expect(result.notes == [.scannedPagesMadeSearchable])
        #expect(result.frames == 1)

        let found = text(of: output)
        let positions = ["Invoice", "4821", "scanned", "Total", "129"].map { found.range(of: $0)?.lowerBound }
        #expect(positions.allSatisfy { $0 != nil }, "recognised: \(found)")
        let ordered = positions.compactMap { $0 }
        #expect(ordered == ordered.sorted(), "words out of order: \(found)")

        let before = try PDFRasterizer.render(try #require(PDFDocument(url: input)?.page(at: 0)?.pageRef), maxPixels: 10_000_000)
        let after = try PDFRasterizer.render(try #require(PDFDocument(url: output)?.page(at: 0)?.pageRef), maxPixels: 10_000_000)
        #expect(ScanFixtures.difference(before.image, after.image) < 1, "the invisible text layer changed how the page looks")
    }

    @Test func pagesWithTextAreLeftAlone() async throws {
        let input = try file("mixed.pdf", ScanFixtures.pdf([.text("Already digital text on this page"), .scan(ScanFixtures.lines)]))
        let (output, result) = try await run(.ocr(languages: nil), input)
        #expect(result.frames == 1)
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 2)
        #expect(document.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "Already digital text on this page")
        #expect(document.page(at: 1)?.string?.contains("Invoice") == true)

        let digital = try file("digital.pdf", ScanFixtures.pdf([.text("Already digital text on this page")]))
        await #expect(throws: ConversionError.self) { try await run(.ocr(languages: nil), digital) }
    }

    @Test func rotatedScansAreRecognised() async throws {
        let document = try #require(PDFDocument(data: ScanFixtures.pdf([.scan(ScanFixtures.lines)])))
        document.page(at: 0)?.rotation = 90
        let input = scratch.appendingPathComponent("rotated.pdf")
        #expect(document.write(to: input))
        let (output, _) = try await run(.ocr(languages: ["en"]), input)
        #expect(text(of: output).contains("scanned pages"))
        #expect(PDFDocument(url: output)?.page(at: 0)?.rotation == 90)
    }

    @Test(.enabled(if: TextRecognizer.supports("hi"), "Vision on this Mac doesn't read Hindi"))
    func readsHindiNextToEnglish() async throws {
        let png = try file("hindi.png", Fixtures.encode([ScanFixtures.image(["नमस्ते दुनिया", "Hello world 42"])], as: .png))
        let (output, result) = try await run(.ocr(languages: ["hi-IN", "en-US"]), png, from: .png, to: .txt)
        let found = try String(contentsOf: output, encoding: .utf8)
        #expect(found.contains("नमस्ते"), "recognised: \(found)")
        #expect(found.contains("Hello"), "recognised: \(found)")
        #expect(result.notes == [.textRecognisedInPicture])
    }

    // MARK: Text out

    @Test func copiesTextFromAPicture() async throws {
        let png = try file("note.png", Fixtures.encode([ScanFixtures.image()], as: .png))
        let (txt, _) = try await run(.ocr(languages: nil), png, from: .png, to: .txt)
        let plain = try String(contentsOf: txt, encoding: .utf8)
        #expect(plain.contains("Invoice number 4821"), "recognised: \(plain)")
        #expect(plain.range(of: "Invoice")!.lowerBound < plain.range(of: "Total")!.lowerBound)

        let (docx, _) = try await run(.ocr(languages: nil), png, from: .png, to: .docx)
        #expect(FileFormat.detect(at: docx) == .docx)
        let (md, _) = try await run(.ocr(languages: nil), png, from: .png, to: .md)
        #expect(try String(contentsOf: md, encoding: .utf8).contains("rupees"))

        // "JPG to Word" as a plain conversion; picture → Text stays the QR code reader.
        #expect(ConversionMatrix.canConvert(from: .jpeg, to: .docx) && ConversionMatrix.canConvert(from: .png, to: .md))
        #expect(!ConversionMatrix.canConvert(from: .svg, to: .docx) && !ConversionMatrix.canConvert(from: .ico, to: .md))
        let work = scratch.appendingPathComponent("convert", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (word, wordResult) = try await Engine.convert(input: png, request: ConversionRequest(source: .png, target: .docx),
                                                          scratch: work) { _ in }
        #expect(FileFormat.detect(at: word) == .docx && wordResult.notes == [.textRecognisedInPicture])

        let blank = try file("blank.png", Fixtures.encode([Fixtures.frames(1)[0]], as: .png))
        await #expect(throws: ConversionError.noText) { try await run(.ocr(languages: nil), blank, from: .png, to: .txt) }
    }

    @Test func scannedPDFToTextFallsBackToRecognition() throws {
        let (data, notes) = try DocumentConverter.convert(ScanFixtures.pdf([.scan(ScanFixtures.lines)]), from: .pdf, to: .txt)
        #expect(String(decoding: data, as: UTF8.self).contains("Total due 129"))
        #expect(notes.contains(.textRecognisedFromScans))
    }

    // MARK: Pages

    @Test func pageRangesParse() throws {
        #expect(try PageRanges.parse("1-3, 7, 9-", pageCount: 12) == [1, 2, 3, 7, 9, 10, 11, 12])
        #expect(try PageRanges.parse("3; 1 – 2, 2", pageCount: 5) == [3, 1, 2])
        #expect(try PageRanges.parse("-2 5", pageCount: 5) == [1, 2, 5])
        #expect(throws: PageRanges.Failure.empty) { try PageRanges.parse("  , ", pageCount: 5) }
        #expect(throws: PageRanges.Failure.pageZero) { try PageRanges.parse("0-2", pageCount: 5) }
        #expect(throws: PageRanges.Failure.backwards("5-3")) { try PageRanges.parse("5-3", pageCount: 5) }
        #expect(throws: PageRanges.Failure.notAPage("two")) { try PageRanges.parse("1, two", pageCount: 5) }
        #expect(throws: PageRanges.Failure.notAPage("1-2-3")) { try PageRanges.parse("1-2-3", pageCount: 5) }
        #expect(throws: PageRanges.Failure.beyondEnd(page: 9, pageCount: 5)) { try PageRanges.parse("9-", pageCount: 5) }
        #expect(PageRanges.Failure.beyondEnd(page: 9, pageCount: 5).errorDescription == "There is no page 9; this PDF has 5 pages.")
    }

    @Test func addsPageNumbersAndWatermarks() async throws {
        let input = try file("three.pdf", ScanFixtures.pdf([.text("one"), .text("two"), .text("three")]))
        let (numbered, _) = try await run(.addPageNumbers(.pageOfTotal), input)
        #expect(text(of: numbered, page: 1).contains("Page 2 of 3"))
        let (plain, _) = try await run(.addPageNumbers(.number), input)
        #expect(text(of: plain, page: 2).contains("3"))

        let (marked, _) = try await run(.watermark(text: "CONFIDENTIAL", opacity: 0.2), input)
        #expect((0..<3).allSatisfy { text(of: marked, page: $0).contains("CONFIDENTIAL") })
        #expect(text(of: marked, page: 0).contains("one"))
        await #expect(throws: ConversionError.self) { try await run(.watermark(text: "  ", opacity: 0.2), input) }
    }

    // MARK: Passwords

    @Test func passwordRoundTrip() async throws {
        let input = try file("private.pdf", ScanFixtures.pdf([.text("Bank details")]))
        await #expect(throws: ConversionError.self) { try await run(.protect(password: "s3cret ü"), input) }
        let password = "s3cret pass!"
        let (locked, result) = try await run(.protect(password: password), input)
        #expect(result.notes == [.keepPasswordSafe])
        let document = try #require(PDFDocument(url: locked))
        #expect(document.isLocked)
        #expect(!document.unlock(withPassword: "wrong"))
        #expect(document.unlock(withPassword: password))
        #expect(document.page(at: 0)?.string?.contains("Bank details") == true)
        #expect(String(decoding: try Data(contentsOf: locked), as: UTF8.self).contains("/AESV2"), "expected AES encryption")

        await #expect(throws: ConversionError.wrongPassword) { try await run(.removePassword(password: "wrong"), locked) }
        let (open, _) = try await run(.removePassword(password: password), locked)
        let reopened = try #require(PDFDocument(url: open))
        #expect(!reopened.isEncrypted && !reopened.isLocked)
        #expect(reopened.page(at: 0)?.string?.contains("Bank details") == true)

        await #expect(throws: ConversionError.lockedPDF) { try await run(.protect(password: "again"), locked) }
        await #expect(throws: ConversionError.refused("This PDF has no password to remove.")) {
            try await run(.removePassword(password: "x"), input)
        }
    }

    @Test func passwordsTravelOnStdinNotTheCommandLine() throws {
        let original = ConversionRequest(source: .pdf, target: .pdf, options: ConversionOptions(pdf: .protect(password: "hunter2 ✓")))
        var request = original
        let secret = try #require(WorkerSecret.extract(from: &request))
        #expect(secret == "hunter2 ✓")
        #expect(!(try WorkerProtocol.encode(request)).contains("hunter2"))
        #expect(request.options.secretOnStdin == true)

        let body = Data((0..<300_000).map { UInt8($0 % 251) })
        let source = try file("body.bin", body)
        let handle = try FileHandle(forReadingFrom: source)
        let stdin = try WorkerSecret.stdin(prefixing: secret, to: handle)
        try handle.close() // the feeder has its own descriptor
        var received = request
        WorkerSecret.restore(try WorkerSecret.receive(from: stdin), into: &received)
        #expect(received == original)
        #expect(try stdin.readToEnd() == body)
        try stdin.close()
    }
}
