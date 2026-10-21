import AmeyaCore
import Foundation
import PDFKit

/// Page-level PDF tools (PDFKit): merge, split, rotate, delete and reorder pages.
/// Page numbers in `PDFAction` are 1-based. Runs inside the worker.
public enum PDFTools {
    /// Most pages one job may produce or read, so a crafted file can't exhaust memory.
    static let maxPages = 10_000

    /// Runs `action` over `inputs` (formats from `request.inputs`, or `request.source` for one input).
    /// Writes into `scratch`. Splits always report `outputNames`, even for a single piece.
    @MainActor
    public static func run(
        _ action: AmeyaCore.PDFAction, // PDFKit has its own PDFAction (link actions)
        inputs: [URL],
        request: ConversionRequest,
        scratch: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> (outputs: [URL], result: ConversionResult) {
        let formats = request.inputs ?? [request.source ?? (inputs.first.flatMap(FileFormat.detect(at:)) ?? .pdf)]
        guard !inputs.isEmpty, formats.count == inputs.count else {
            throw ConversionError.invalidData("the list of files doesn't match the files sent")
        }

        if case .merge = action {
            let document = try merge(inputs, formats: formats, options: request.options, progress: progress)
            let output = try save(document, as: "output.pdf", in: scratch)
            return ([output], result(for: [output], pages: document.pageCount, named: false))
        }

        guard inputs.count == 1 else { throw ConversionError.invalidData("this PDF tool takes one file at a time") }
        guard formats[0] == .pdf else { throw ConversionError.unsupportedConversion(from: formats[0], to: .pdf) }
        let document = try open(inputs[0])
        let count = document.pageCount

        switch action {
        case .merge:
            preconditionFailure("handled above")

        case .splitEveryPage:
            let digits = max(3, String(count).count)
            let pieces = (1...count).map { number in
                (name: "Page \(String(repeating: "0", count: digits - String(number).count))\(number).pdf", pages: [number])
            }
            return try split(document, into: pieces, scratch: scratch, progress: progress)

        case .splitRanges(let ranges):
            guard !ranges.isEmpty else { throw ConversionError.invalidData("no page ranges were given") }
            let pieces = try ranges.map { range in
                try validate(Array(range), pageCount: count)
                let name = range.count == 1 ? "Page \(range.lowerBound).pdf" : "Pages \(range.lowerBound)-\(range.upperBound).pdf"
                return (name: name, pages: Array(range))
            }
            guard Set(pieces.map(\.name)).count == pieces.count else {
                throw ConversionError.invalidData("the same page range was given twice")
            }
            return try split(document, into: pieces, scratch: scratch, progress: progress)

        case .rotate(let degrees, let pages):
            guard degrees % 90 == 0 else { throw ConversionError.invalidData("pages can only turn in steps of 90°") }
            let targets = pages ?? Array(1...count)
            try validate(targets, pageCount: count)
            for number in Set(targets) {
                guard let page = document.page(at: number - 1) else { throw ConversionError.unreadable }
                page.rotation = (((page.rotation + degrees) % 360) + 360) % 360
            }

        case .deletePages(let pages):
            try validate(pages, pageCount: count)
            let doomed = Set(pages)
            guard doomed.count < count else { throw ConversionError.invalidData("a PDF needs at least one page left") }
            for index in doomed.sorted(by: >) { document.removePage(at: index - 1) }

        case .reorder(let order):
            // Any list of existing pages: a permutation, a subset (extract pages) or repeats.
            guard !order.isEmpty else { throw ConversionError.invalidData("the new page order is empty") }
            try validate(order, pageCount: count)
            guard order.count <= maxPages else { throw ConversionError.dataLimit("more than \(maxPages) pages") }
            let reordered = PDFDocument()
            for number in order {
                guard let page = document.page(at: number - 1)?.copy() as? PDFPage else { throw ConversionError.unreadable }
                reordered.insert(page, at: reordered.pageCount)
            }
            let output = try save(reordered, as: "output.pdf", in: scratch)
            progress(1)
            return ([output], result(for: [output], pages: reordered.pageCount, named: false))

        case .compress(let quality, let targetBytes): // see PDFCompressor.swift
            let (output, pages, notes) = try PDFCompressor.compress(input: inputs[0], quality: quality, targetBytes: targetBytes,
                                                                    scratch: scratch, progress: progress)
            return ([output], ConversionResult(outputBytes: VideoEditor.fileSize(output), frames: pages, notes: notes))

        case .preview:
            throw ConversionError.invalidData("previews are handled before the PDF tools")

        case .ocr, .addPageNumbers, .watermark, .protect, .removePassword:
            // Text recognition, stamps and passwords (PDFToolbox.swift).
            return try PDFToolbox.run(action, inputs: inputs, request: request, scratch: scratch, progress: progress)
        }

        let output = try save(document, as: "output.pdf", in: scratch)
        progress(1)
        return ([output], result(for: [output], pages: document.pageCount, named: false))
    }

    // MARK: Steps

    /// Opens a PDF and refuses password-protected ones.
    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw ConversionError.unreadable }
        if document.isLocked && !document.unlock(withPassword: "") { throw ConversionError.lockedPDF }
        guard document.pageCount > 0 else { throw ConversionError.unreadable }
        guard document.pageCount <= maxPages else { throw ConversionError.dataLimit("more than \(maxPages) pages") }
        return document
    }

    /// All inputs in order; images become pages through the image → PDF path.
    static func merge(
        _ inputs: [URL],
        formats: [FileFormat],
        options: ConversionOptions,
        progress: (Double) -> Void
    ) throws -> PDFDocument {
        let merged = PDFDocument()
        for (index, (input, format)) in zip(inputs, formats).enumerated() {
            let part: PDFDocument
            switch format.family {
            case .document where format == .pdf:
                part = try open(input)
            case .image:
                let data = try Data(contentsOf: input, options: .mappedIfSafe)
                var imageOptions = options
                imageOptions.pdf = nil
                let (pdf, _) = try ImageConverter.convert(data, request: ConversionRequest(source: format, target: .pdf, options: imageOptions))
                guard let document = PDFDocument(data: pdf) else { throw ConversionError.encodeFailed(.pdf) }
                part = document
            default:
                throw ConversionError.unsupportedConversion(from: format, to: .pdf)
            }
            guard merged.pageCount + part.pageCount <= maxPages else {
                throw ConversionError.dataLimit("more than \(maxPages) pages")
            }
            for pageIndex in 0..<part.pageCount {
                guard let page = part.page(at: pageIndex)?.copy() as? PDFPage else { throw ConversionError.unreadable }
                merged.insert(page, at: merged.pageCount)
            }
            progress(Double(index + 1) / Double(inputs.count) * 0.9)
        }
        return merged
    }

    private static func split(
        _ document: PDFDocument,
        into pieces: [(name: String, pages: [Int])],
        scratch: URL,
        progress: (Double) -> Void
    ) throws -> (outputs: [URL], result: ConversionResult) {
        let folder = scratch.appendingPathComponent("pieces", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var outputs: [URL] = []
        for (index, piece) in pieces.enumerated() {
            let part = PDFDocument()
            for number in piece.pages {
                guard let page = document.page(at: number - 1)?.copy() as? PDFPage else { throw ConversionError.unreadable }
                part.insert(page, at: part.pageCount)
            }
            outputs.append(try save(part, as: piece.name, in: folder))
            progress(Double(index + 1) / Double(pieces.count))
        }
        return (outputs, result(for: outputs, pages: pieces.reduce(0) { $0 + $1.pages.count }, named: true))
    }

    private static func validate(_ pages: [Int], pageCount: Int) throws {
        guard !pages.isEmpty else { throw ConversionError.invalidData("no pages were chosen") }
        if let bad = pages.first(where: { !(1...pageCount).contains($0) }) {
            throw ConversionError.invalidData("page \(bad) doesn't exist; this PDF has \(pageCount) page\(pageCount == 1 ? "" : "s")")
        }
    }

    private static func save(_ document: PDFDocument, as name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        guard document.write(to: url) else { throw ConversionError.encodeFailed(.pdf) }
        return url
    }

    private static func result(for outputs: [URL], pages: Int, named: Bool) -> ConversionResult {
        let bytes = outputs.reduce(0) { total, url in
            total + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        }
        return ConversionResult(outputBytes: bytes, frames: pages, notes: [],
                                outputNames: named ? outputs.map(\.lastPathComponent) : nil)
    }
}
