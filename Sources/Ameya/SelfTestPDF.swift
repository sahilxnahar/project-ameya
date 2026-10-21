import AmeyaCore
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit

/// Self-test checks for the PDF toolbox and text recognition, all through the sandboxed worker.
extension SelfTest.Checker {
    mutating func checkPDFToolbox() async {
        let catalog = ToolCatalog(writable: FileFormat.systemWritable())
        func tool(_ id: String) -> Tool { catalog.tools.first { $0.id == id }! }

        do {
            // A scan: words drawn as a picture, so the PDF has no text layer.
            let scan = directory.appendingPathComponent("scan.pdf")
            try SelfTest.makeScannedPDF(lines: ["Ameya self test", "Invoice 4821"]).write(to: scan)
            let searchable = directory.appendingPathComponent("scan (searchable).pdf")
            if let result = await runPDFTool(tool("pdf.searchable"), scan, to: searchable) {
                let text = PDFDocument(url: searchable)?.page(at: 0)?.string ?? ""
                pdfReport(text.contains("Ameya") && text.contains("4821") && result.notes == [.scannedPagesMadeSearchable],
                          "make PDF searchable", "recognised \(text.debugDescription)")
            }

            // Picture → Word, by recognising its words.
            let picture = directory.appendingPathComponent("note.png")
            try SelfTest.textPNG(lines: ["Copy this sentence"]).write(to: picture)
            let docx = directory.appendingPathComponent("note.docx")
            do {
                _ = try await runner.run(inputs: [picture], destination: docx,
                                         request: ConversionRequest(source: .png, target: .docx))
                pdfReport(FileFormat.detect(at: docx) == .docx, "picture to Word (recognised text)", "not a DOCX")
            } catch {
                pdfReport(false, "picture to Word (recognised text)", error.localizedDescription)
            }

            let three = directory.appendingPathComponent("three-pages.pdf")
            try SelfTest.makePDF(pages: 3).write(to: three)
            let fewer = directory.appendingPathComponent("three-pages (fewer pages).pdf")
            if await runPDFTool(tool("pdf.removePages"), three, to: fewer, action: .deletePages([2])) != nil {
                pdfReport(SelfTest.pageCount(fewer) == 2, "remove pages", "got \(SelfTest.pageCount(fewer)) pages")
            }

            let numbered = directory.appendingPathComponent("three-pages (numbered).pdf")
            if await runPDFTool(tool("pdf.pageNumbers"), three, to: numbered, action: .addPageNumbers(.pageOfTotal)) != nil {
                let text = PDFDocument(url: numbered)?.page(at: 1)?.string ?? ""
                pdfReport(text.contains("Page 2 of 3"), "add page numbers", "page 2 reads \(text.debugDescription)")
            }

            // The password travels to the worker on stdin; the copy must open only with it.
            let password = "Self-test pass 7!"
            let locked = directory.appendingPathComponent("three-pages (protected).pdf")
            if await runPDFTool(tool("pdf.protect"), three, to: locked, action: .protect(password: password)) != nil {
                let document = PDFDocument(url: locked)
                let opens = document?.isLocked == true && document?.unlock(withPassword: "wrong") == false
                    && document?.unlock(withPassword: password) == true && document?.pageCount == 3
                pdfReport(opens, "password-protect PDF", "the copy didn't lock and reopen as expected")

                let unlocked = directory.appendingPathComponent("three-pages (unlocked).pdf")
                if await runPDFTool(tool("pdf.removePassword"), locked, to: unlocked, action: .removePassword(password: password)) != nil {
                    let open = PDFDocument(url: unlocked)
                    pdfReport(open?.isEncrypted == false && open?.pageCount == 3, "remove password", "still encrypted")
                }
            }
        } catch {
            pdfReport(false, "PDF toolbox setup", error.localizedDescription)
        }
    }

    /// Runs a tool's request, with a panel's action when given, the way JobStore does.
    private mutating func runPDFTool(_ tool: Tool, _ input: URL, to destination: URL,
                                     action: AmeyaCore.PDFAction? = nil) async -> ConversionResult? {
        var request = tool.makeRequest(.pdf)
        if let action { request.options = ConversionOptions(pdf: action) }
        do {
            return try await runner.run(inputs: [input], destination: destination, request: request)
        } catch {
            pdfReport(false, tool.title, error.localizedDescription)
            return nil
        }
    }

    private mutating func pdfReport(_ passed: Bool, _ label: String, _ problem: String) {
        print(passed ? "PASS pdf \(label)" : "FAIL pdf \(label): \(problem)")
        if !passed { allPassed = false }
    }
}

extension SelfTest {
    /// Black text on white, 1275×1650 (150 dpi US Letter).
    static func textImage(lines: [String]) throws -> CGImage {
        let (width, height) = (1275, 1650)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.featureUnsupported) }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 44, nil)
        for (index, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]))
            context.textPosition = CGPoint(x: 120, y: CGFloat(height - 200 - index * 100))
            CTLineDraw(line, context)
        }
        guard let image = context.makeImage() else { throw CocoaError(.featureUnsupported) }
        return image
    }

    static func makeScannedPDF(lines: [String]) throws -> Data {
        let image = try textImage(lines: lines)
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw CocoaError(.featureUnsupported)
        }
        context.beginPage(mediaBox: &box)
        context.draw(image, in: box)
        context.endPage()
        context.closePDF()
        return data as Data
    }

    static func textPNG(lines: [String]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.featureUnsupported)
        }
        CGImageDestinationAddImage(destination, try textImage(lines: lines), nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
