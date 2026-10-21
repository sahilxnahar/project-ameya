import AmeyaCore
import AmeyaEngines
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing

/// The worker's preview mode: everything the page panels need, so the app never opens the PDF.
@Suite("PDF preview")
@MainActor
struct PDFPreviewTests {
    let scratch: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-preview-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    /// A PDF with one page per size; each page has a dark square so images aren't blank.
    static func pdf(sizes: [CGSize], password: String? = nil) throws -> Data {
        let data = NSMutableData()
        var info: [CFString: Any] = [:]
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password
        }
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, info as CFDictionary) else { throw CocoaError(.featureUnsupported) }
        for size in sizes {
            var box = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &box)
            context.setFillColor(CGColor(gray: 0.1, alpha: 1))
            context.fill(CGRect(x: 10, y: 10, width: size.width / 2, height: size.height / 2))
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }

    private func preview(_ pdf: Data, password: String = "", side: Int = 220) async throws
        -> (info: PDFPreviewInfo, files: [String: URL], result: ConversionResult) {
        let input = scratch.appendingPathComponent("\(UUID().uuidString).pdf")
        try pdf.write(to: input)
        let work = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let request = ConversionRequest(source: .pdf, target: .pdf,
                                        options: ConversionOptions(pdf: .preview(password: password, thumbnailSide: side)))
        let (outputs, result) = try await Engine.run(inputs: [input], request: request, scratch: work) { _ in }
        let names = try #require(result.outputNames)
        #expect(names.first == PDFPreviewInfo.fileName)
        #expect(names.count == outputs.count)
        let files = Dictionary(uniqueKeysWithValues: zip(names, outputs))
        let info = try JSONDecoder().decode(PDFPreviewInfo.self, from: Data(contentsOf: try #require(files[PDFPreviewInfo.fileName])))
        #expect(info.isConsistent)
        return (info, files, result)
    }

    private func pixelSize(_ url: URL) throws -> (Int, Int) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    @Test func reportsPageCountSizesAndSmallImages() async throws {
        let sizes = [CGSize(width: 612, height: 792), CGSize(width: 792, height: 612), CGSize(width: 300, height: 200)]
        let (info, files, result) = try await preview(try Self.pdf(sizes: sizes))
        #expect(info.pageCount == 3)
        #expect(!info.locked)
        #expect(!info.isTruncated)
        #expect(info.thumbnailCount == 3)
        #expect(info.pages.map(\.width) == [612, 792, 300])
        #expect(info.pages.map(\.height) == [792, 612, 200])
        #expect(result.frames == 3)
        #expect(result.outputNames == [PDFPreviewInfo.fileName] + (1...3).map(PDFPreviewInfo.thumbnailName))
        for page in 1...3 {
            let (width, height) = try pixelSize(try #require(files[PDFPreviewInfo.thumbnailName(page)]))
            #expect(max(width, height) == 220)
            let expected = sizes[page - 1].width / sizes[page - 1].height
            #expect(abs(Double(width) / Double(height) - expected) < 0.02)
        }
    }

    @Test func pageRotationIsReportedAndSizesAreUpright() async throws {
        let document = try #require(PDFDocument(data: try Self.pdf(sizes: [CGSize(width: 600, height: 400)])))
        document.page(at: 0)?.rotation = 90
        let (info, files, _) = try await preview(try #require(document.dataRepresentation()))
        #expect(info.pages == [.init(width: 400, height: 600, rotation: 90)])
        let (width, height) = try pixelSize(try #require(files[PDFPreviewInfo.thumbnailName(1)]))
        #expect(height == 220 && width < height)
    }

    @Test func imagesStopAtTheCapAndSayTheListWasCut() async throws {
        let count = PDFPreviewInfo.maxThumbnails + 20
        let (info, files, _) = try await preview(try Self.pdf(sizes: Array(repeating: CGSize(width: 100, height: 100), count: count)), side: 32)
        #expect(info.pageCount == count)
        #expect(info.pages.count == count)
        #expect(info.thumbnailCount == PDFPreviewInfo.maxThumbnails)
        #expect(info.isTruncated)
        #expect(files.count == 1 + PDFPreviewInfo.maxThumbnails)
        #expect(files[PDFPreviewInfo.thumbnailName(PDFPreviewInfo.maxThumbnails)] != nil)
        #expect(files[PDFPreviewInfo.thumbnailName(PDFPreviewInfo.maxThumbnails + 1)] == nil)
    }

    @Test func countOnlyRequestSendsNoImages() async throws {
        let (info, files, _) = try await preview(try Self.pdf(sizes: [CGSize(width: 50, height: 50), CGSize(width: 50, height: 50)]), side: 0)
        #expect(info.pageCount == 2)
        #expect(info.thumbnailCount == 0)
        #expect(files.keys.sorted() == [PDFPreviewInfo.fileName])
    }

    @Test func absurdSizesStayInsideTheImageLimit() async throws {
        let (info, files, _) = try await preview(try Self.pdf(sizes: [CGSize(width: 14_000, height: 20)]), side: 5_000)
        #expect(info.thumbnailCount == 1)
        let (width, height) = try pixelSize(try #require(files[PDFPreviewInfo.thumbnailName(1)]))
        #expect(width <= PDFPreviewInfo.thumbnailSideRange.upperBound && height >= 1)
    }

    @Test func lockedPDFIsReportedWithoutPagesUntilThePasswordIsGiven() async throws {
        let locked = try Self.pdf(sizes: [CGSize(width: 200, height: 300), CGSize(width: 200, height: 300)], password: "open sesame")
        for attempt in ["", "wrong"] {
            let (info, files, _) = try await preview(locked, password: attempt)
            #expect(info.locked)
            #expect(info.pageCount == 0)
            #expect(info.pages.isEmpty)
            #expect(files.keys.sorted() == [PDFPreviewInfo.fileName])
        }
        let (info, files, _) = try await preview(locked, password: "open sesame")
        #expect(!info.locked)
        #expect(info.pageCount == 2)
        #expect(files.count == 3)
    }

    @Test func notAPDFIsRefused() async throws {
        await #expect(throws: ConversionError.self) { try await preview(Data("%PDF-1.7 nonsense".utf8)) }
    }

    @Test func passwordTravelsOnStdinNotTheCommandLine() throws {
        var request = ConversionRequest(source: .pdf, target: .pdf,
                                        options: ConversionOptions(pdf: .preview(password: "s3cret", thumbnailSide: 220)))
        #expect(WorkerSecret.extract(from: &request) == "s3cret")
        #expect(!(try WorkerProtocol.encode(request)).contains("s3cret"))
        var empty = ConversionRequest(source: .pdf, target: .pdf,
                                      options: ConversionOptions(pdf: .preview(password: "", thumbnailSide: 220)))
        #expect(WorkerSecret.extract(from: &empty) == nil)
    }
}
