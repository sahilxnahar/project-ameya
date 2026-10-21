import AmeyaCore
import CoreGraphics
import Foundation
import Testing

private final class PreviewBundleMarker {}

/// The real worker answering a preview request the way the app's page panels ask for it: a folder
/// in the temporary directory holding `info.json` and small page images.
@Suite("PDF preview through the worker", .serialized)
struct PDFPreviewWorkerTests {
    let directory: URL
    let runner: WorkerRunner

    init() throws {
        let products = Bundle(for: PreviewBundleMarker.self).bundleURL.deletingLastPathComponent()
        let worker = products.appendingPathComponent("AmeyaWorker")
        try #require(FileManager.default.isExecutableFile(atPath: worker.path), "Build AmeyaWorker first (swift build)")
        runner = WorkerRunner(executable: worker, timeout: .seconds(60))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-preview-it-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func samplePDF(pages: Int, password: String? = nil) throws -> URL {
        let data = NSMutableData()
        var info: [CFString: Any] = [:]
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password
        }
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: nil, info as CFDictionary))
        for _ in 0..<pages {
            var box = CGRect(x: 0, y: 0, width: 300, height: 200)
            context.beginPage(mediaBox: &box)
            context.fill(CGRect(x: 20, y: 20, width: 100, height: 60))
            context.endPage()
        }
        context.closePDF()
        let url = directory.appendingPathComponent("\(UUID().uuidString).pdf")
        try (data as Data).write(to: url)
        return url
    }

    private func preview(_ input: URL, password: String = "", side: Int = 220) async throws -> (folder: URL, info: PDFPreviewInfo) {
        let folder = directory.appendingPathComponent("ameya-preview-\(UUID().uuidString)", isDirectory: true)
        let request = ConversionRequest(source: .pdf, target: .pdf,
                                        options: ConversionOptions(pdf: .preview(password: password, thumbnailSide: side)))
        let result = try await runner.run(inputs: [input], destination: folder, request: request)
        let names = try #require(result.outputNames)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == names.sorted())
        let info = try JSONDecoder().decode(PDFPreviewInfo.self, from: Data(contentsOf: folder.appendingPathComponent(PDFPreviewInfo.fileName)))
        return (folder, info)
    }

    @Test func foldersHoldTheInfoAndImagesAndLeaveNothingElseBehind() async throws {
        let (folder, info) = try await preview(try samplePDF(pages: 12))
        #expect(info.pageCount == 12 && info.thumbnailCount == 12 && !info.locked)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(PDFPreviewInfo.thumbnailName(12)).path))
        let png = try Data(contentsOf: folder.appendingPathComponent(PDFPreviewInfo.thumbnailName(1)))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(png.count < PDFPreviewInfo.maxFileBytes)
        // The runner's hidden partial files are gone.
        let hidden = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".partial") }
        #expect(hidden.isEmpty)
    }

    @Test func longPDFsGetImagesForTheFirstPagesOnly() async throws {
        let (folder, info) = try await preview(try samplePDF(pages: PDFPreviewInfo.maxThumbnails + 3), side: 40)
        #expect(info.pageCount == PDFPreviewInfo.maxThumbnails + 3)
        #expect(info.thumbnailCount == PDFPreviewInfo.maxThumbnails)
        #expect(info.isTruncated)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.count == PDFPreviewInfo.maxThumbnails + 1)
    }

    @Test func lockedPDFsAreReportedAndOpenWithThePasswordSentOnStdin() async throws {
        let locked = try samplePDF(pages: 2, password: "worker pass")
        let (_, shut) = try await preview(locked)
        #expect(shut.locked && shut.pageCount == 0)
        let (_, wrong) = try await preview(locked, password: "nope")
        #expect(wrong.locked)
        let (_, open) = try await preview(locked, password: "worker pass")
        #expect(!open.locked && open.pageCount == 2 && open.thumbnailCount == 2)
    }

    @Test func aBrokenPDFFailsCleanly() async throws {
        let broken = directory.appendingPathComponent("broken.pdf")
        try Data("%PDF-1.4\n1 0 obj<<>>endobj\ngarbage".utf8).write(to: broken)
        let folder = directory.appendingPathComponent("never")
        let request = ConversionRequest(source: .pdf, target: .pdf,
                                        options: ConversionOptions(pdf: .preview(password: "", thumbnailSide: 220)))
        await #expect(throws: WorkerError.self) { try await runner.run(inputs: [broken], destination: folder, request: request) }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aStuckPreviewIsStoppedByTheTimeout() async throws {
        var quick = runner
        quick.timeout = .seconds(1)
        let request = ConversionRequest(source: .pdf, target: .pdf,
                                        options: ConversionOptions(pdf: .preview(password: "", thumbnailSide: 220), debugDelaySeconds: 30))
        await #expect(throws: WorkerError.timedOut(seconds: 1)) {
            try await quick.run(inputs: [try samplePDF(pages: 1)], destination: directory.appendingPathComponent("slow"), request: request)
        }
    }
}
