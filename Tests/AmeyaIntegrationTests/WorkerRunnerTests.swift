import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO
import Testing

private final class BundleMarker {}

/// Drives the real `AmeyaWorker` executable built next to this test bundle.
@Suite("Worker process", .serialized)
struct WorkerRunnerTests {
    let directory: URL
    let source: URL
    let runner: WorkerRunner

    init() throws {
        let products = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
        let worker = products.appendingPathComponent("AmeyaWorker")
        try #require(FileManager.default.isExecutableFile(atPath: worker.path), "Build AmeyaWorker first (swift build)")
        runner = WorkerRunner(executable: worker, timeout: .seconds(30))

        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-it-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("input.png")
        try Self.samplePNG().write(to: source)
    }

    @Test func convertsAndPlacesTheOutput() async throws {
        let destination = directory.appendingPathComponent("input.jpg")
        let progress = ProgressLog()
        let result = try await runner.run(input: source, destination: destination, request: ConversionRequest(target: .jpeg)) {
            progress.append($0)
        }
        #expect(FileFormat.detect(at: destination) == .jpeg)
        #expect(result.outputBytes == (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int))
        #expect(progress.values.last == 1)
        #expect(leftovers().isEmpty)
    }

    @Test func neverOverwritesAnExistingFile() async throws {
        let destination = directory.appendingPathComponent("taken.jpg")
        try Data("keep me".utf8).write(to: destination)
        await #expect(throws: WorkerError.outputExists("taken.jpg")) {
            try await runner.run(input: source, destination: destination, request: ConversionRequest(target: .jpeg))
        }
        #expect(try Data(contentsOf: destination) == Data("keep me".utf8))
        #expect(leftovers().isEmpty)
    }

    @Test func reportsConverterErrors() async throws {
        let garbage = directory.appendingPathComponent("garbage.png")
        try Data("definitely not a png".utf8).write(to: garbage)
        let destination = directory.appendingPathComponent("garbage.jpg")
        do {
            _ = try await runner.run(input: garbage, destination: destination, request: ConversionRequest(target: .jpeg))
            Issue.record("Expected a failure")
        } catch let error as WorkerError {
            guard case .failed(let message) = error else { Issue.record("Unexpected \(error)"); return }
            #expect(message.contains("couldn't be read"))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(leftovers().isEmpty)
    }

    @Test func timesOutAndCleansUp() async throws {
        var timed = runner
        timed.timeout = .seconds(1)
        let destination = directory.appendingPathComponent("slow.jpg")
        let request = ConversionRequest(target: .jpeg, options: ConversionOptions(debugDelaySeconds: 30))
        let started = ContinuousClock.now
        await #expect(throws: WorkerError.timedOut(seconds: 1)) {
            try await timed.run(input: source, destination: destination, request: request)
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(leftovers().isEmpty)
    }

    @Test func cancellationKillsTheWorker() async throws {
        let destination = directory.appendingPathComponent("cancelled.jpg")
        let request = ConversionRequest(target: .jpeg, options: ConversionOptions(debugDelaySeconds: 30))
        let runner = runner
        let source = source
        let task = Task { try await runner.run(input: source, destination: destination, request: request) }
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: WorkerError.cancelled) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(leftovers().isEmpty)
    }

    @Test func aCrashFailsOnlyThatJob() async throws {
        let crashed = directory.appendingPathComponent("crash.jpg")
        let crashRequest = ConversionRequest(target: .jpeg, options: ConversionOptions(debugCrash: true))
        do {
            _ = try await runner.run(input: source, destination: crashed, request: crashRequest)
            Issue.record("Expected a crash")
        } catch let error as WorkerError {
            guard case .crashed = error else { Issue.record("Unexpected \(error)"); return }
        }
        // The next job runs normally.
        let next = directory.appendingPathComponent("after-crash.png")
        _ = try await runner.run(input: source, destination: next, request: ConversionRequest(target: .tiff))
        #expect(FileManager.default.fileExists(atPath: next.path))
    }

    @Test func mergesSeveralInputsIntoOnePDF() async throws {
        let first = directory.appendingPathComponent("a.pdf")
        let second = directory.appendingPathComponent("b.pdf")
        try Self.pdf(pages: 2).write(to: first)
        try Self.pdf(pages: 1).write(to: second)
        let destination = directory.appendingPathComponent("a (merged).pdf")
        let request = ConversionRequest(source: .pdf, target: .pdf, options: ConversionOptions(pdf: .merge),
                                        inputs: [.pdf, .png, .pdf])
        let result = try await runner.run(inputs: [first, source, second], destination: destination, request: request, temporaryDirectory: bundleFolder())
        #expect(result.outputNames == nil)
        #expect(Self.pageCount(destination) == 4)
        #expect(leftovers().isEmpty)
        #expect(temporaryBundles().isEmpty)
    }

    @Test func splitsIntoAFolder() async throws {
        let pdf = directory.appendingPathComponent("three.pdf")
        try Self.pdf(pages: 3).write(to: pdf)
        let destination = directory.appendingPathComponent("three (pages)", isDirectory: true)
        let request = ConversionRequest(source: .pdf, target: .pdf, options: ConversionOptions(pdf: .splitEveryPage))
        let result = try await runner.run(input: pdf, destination: destination, request: request)
        #expect(result.outputNames == ["Page 001.pdf", "Page 002.pdf", "Page 003.pdf"])
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
        #expect(names == result.outputNames)
        #expect(names.allSatisfy { Self.pageCount(destination.appendingPathComponent($0)) == 1 })
        #expect(leftovers().isEmpty)
    }

    @Test func neverOverwritesAnExistingFolder() async throws {
        let pdf = directory.appendingPathComponent("two.pdf")
        try Self.pdf(pages: 2).write(to: pdf)
        let destination = directory.appendingPathComponent("two (pages)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: destination.appendingPathComponent("mine.txt"))
        let request = ConversionRequest(source: .pdf, target: .pdf, options: ConversionOptions(pdf: .splitEveryPage))
        await #expect(throws: WorkerError.outputExists("two (pages)")) {
            try await runner.run(input: pdf, destination: destination, request: request)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["mine.txt"])
        #expect(leftovers().isEmpty)
    }

    @Test func cleansUpWhenAMultiFileJobFails() async throws {
        let garbage = directory.appendingPathComponent("broken.pdf")
        try Data("%PDF-1.4 nothing here".utf8).write(to: garbage)
        let destination = directory.appendingPathComponent("broken (merged).pdf")
        let request = ConversionRequest(source: .pdf, target: .pdf, options: ConversionOptions(pdf: .merge), inputs: [.pdf, .png])
        await #expect(throws: WorkerError.self) {
            try await runner.run(inputs: [garbage, source], destination: destination, request: request, temporaryDirectory: bundleFolder())
        }
        let folder = directory.appendingPathComponent("broken (pages)", isDirectory: true)
        let split = ConversionRequest(source: .pdf, target: .pdf, options: ConversionOptions(pdf: .splitEveryPage))
        await #expect(throws: WorkerError.self) { try await runner.run(input: garbage, destination: folder, request: split) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(leftovers().isEmpty)
        #expect(temporaryBundles().isEmpty)
    }

    @Test func editsKeepTheSourceFormat() async throws {
        let destination = directory.appendingPathComponent("input (rotated).png")
        let request = ConversionRequest(source: .png, target: .png, options: ConversionOptions(image: ImageEdits(rotation: 90)))
        let result = try await runner.run(input: source, destination: destination, request: request)
        #expect(result.outputBytes > 0)
        #expect(FileFormat.detect(at: destination) == .png)
    }

    /// A private folder for the runner's temporary input bundles, so the check below sees only this test's.
    private func bundleFolder() -> URL {
        let folder = directory.appendingPathComponent("bundles", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Input bundles the runner left behind.
    private func temporaryBundles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: bundleFolder().path)) ?? []
    }

    private static func pdf(pages: Int) -> Data {
        let data = NSMutableData()
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: nil, nil)!
        for _ in 0..<pages {
            var box = CGRect(x: 0, y: 0, width: 200, height: 100)
            context.beginPage(mediaBox: &box)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }

    private static func pageCount(_ url: URL) -> Int {
        guard let provider = CGDataProvider(url: url as CFURL), let document = CGPDFDocument(provider) else { return 0 }
        return document.numberOfPages
    }

    /// Hidden `.partial` files left behind by a failed job.
    private func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".partial") }
    }

    private static func samplePNG() throws -> Data {
        let context = CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ value: Double) { lock.withLock { storage.append(value) } }
    var values: [Double] { lock.withLock { storage } }
}
