import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO

/// Comic book archives: CBZ (ZIP) and CBR (RAR, read-only) of page images.
///
/// Pages are the archive's pictures in natural reading order ("2.jpg" before "10.jpg"),
/// ignoring macOS resource forks, hidden files and anything that isn't a picture.
enum ComicConverter {
    static let limits = ArchiveEntries.Limits(maxEntries: 20_000, maxTotalBytes: 2 << 30)
    static let pictureExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff",
                                                 "heic", "heif", "avif", "jxl", "jp2"]
    /// Metadata files comic tools add; leaving them out isn't worth a warning.
    static let quietFiles: Set<String> = ["comicinfo.xml", "thumbs.db", "desktop.ini"]

    static func isJunk(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == "__MACOSX" || $0.hasPrefix(".") }
    }

    static func isPicture(_ path: String) -> Bool {
        !isJunk(path) && pictureExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// The comic's pages, sorted, and whether other files were left out.
    static func readPages(of input: URL, maxPages: Int) throws -> (pages: [(path: String, data: Data)], skipped: Bool) {
        let archive = try ArchiveEntries.read(input, limits: limits, include: isPicture)
        let paths = archive.paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !paths.isEmpty else { throw BookError.noPages }
        guard paths.count <= maxPages else { throw BookError.tooManyPages(limit: maxPages) }
        let skipped = archive.unsafeSkipped || archive.excluded.contains {
            !isJunk($0) && !quietFiles.contains(($0 as NSString).lastPathComponent.lowercased())
        }
        return (paths.map { ($0, archive.files[$0]!) }, skipped)
    }

    /// One PDF page per picture, sized from the picture's resolution like image → PDF.
    static func toPDF(input: URL, output: URL, options: ConversionOptions, progress: (Double) -> Void) throws -> (notes: [ConversionNote], frames: Int) {
        let (pages, skipped) = try readPages(of: input, maxPages: options.maxFrames)
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else { throw ConversionError.encodeFailed(.pdf) }
        for (index, page) in pages.enumerated() {
            try autoreleasepool {
                let (image, dpi) = try picture(page.data, maxPixels: options.maxPixels)
                var mediaBox = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
                context.beginPage(mediaBox: &mediaBox)
                context.draw(image, in: mediaBox)
                context.endPage()
            }
            progress(Double(index + 1) / Double(pages.count))
        }
        context.closePDF()
        return (skipped ? [.nonImagesSkipped] : [], pages.count)
    }

    /// CBR → CBZ: the same pictures under the same names, stored (they're already compressed).
    static func repack(input: URL, output: URL, options: ConversionOptions, progress: (Double) -> Void) throws -> (notes: [ConversionNote], frames: Int) {
        let (pages, skipped) = try readPages(of: input, maxPages: options.maxFrames)
        var zip = try ZipWriter(url: output)
        for (index, page) in pages.enumerated() {
            try zip.add(page.path, page.data, method: .store)
            progress(Double(index + 1) / Double(pages.count))
        }
        try zip.finish()
        return (skipped ? [.nonImagesSkipped] : [], pages.count)
    }

    /// PDF → CBZ: each page rendered at 144 dpi, saved as JPEG, named 001.jpg, 002.jpg, …
    /// Pages are rendered one at a time so a long PDF doesn't need all its bitmaps in memory.
    static func fromPDF(input: URL, output: URL, options: ConversionOptions, progress: (Double) -> Void) throws -> (notes: [ConversionNote], frames: Int) {
        guard let document = CGPDFDocument(input as CFURL), document.numberOfPages > 0 else { throw ConversionError.unreadable }
        if document.isEncrypted && !document.isUnlocked && !document.unlockWithPassword("") {
            throw ConversionError.lockedPDF
        }
        let count = document.numberOfPages
        guard count <= options.maxFrames else { throw BookError.tooManyPages(limit: options.maxFrames) }
        let digits = max(3, String(count).count)
        var zip = try ZipWriter(url: output)
        for number in 1...count {
            try autoreleasepool {
                guard let page = document.page(at: number) else { throw ConversionError.unreadable }
                let frame = try PDFRasterizer.render(page, maxPixels: options.maxPixels)
                let jpeg = try ImageConverter.encode([frame], as: .jpeg, animated: false, loopCount: 0,
                                                     quality: options.quality ?? 0.85) { _ in }
                let name = String(repeating: "0", count: max(0, digits - String(number).count)) + "\(number).jpg"
                try zip.add(name, jpeg, method: .store)
            }
            progress(Double(number) / Double(count))
        }
        try zip.finish()
        return ([.pagesBecamePictures], count)
    }

    /// A page picture and its resolution. Upright JPEGs are passed through untouched, so the
    /// PDF embeds the original compressed bytes instead of a much larger re-encoded bitmap.
    static func picture(_ data: Data, maxPixels: Int) throws -> (CGImage, Double) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw ConversionError.unreadable }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw ConversionError.unreadable }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxPixels else {
            throw ConversionError.tooLarge(pixels: overflow ? Int.max : pixels, limit: maxPixels)
        }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 >= 36 && $0 <= 1200 ? $0 : nil } ?? 72
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1

        if CGImageSourceGetType(source) as String? == FileFormat.jpeg.typeIdentifier, orientation == 1,
           let provider = CGDataProvider(data: data as CFData),
           let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            return (jpeg, dpi)
        }
        let decoded = try ImageDecoder.decode(data, options: ConversionOptions(maxPixels: maxPixels, maxFrames: 1))
        guard let frame = decoded.frames.first else { throw ConversionError.unreadable }
        return (frame.image, dpi)
    }
}
