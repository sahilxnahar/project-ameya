import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO

/// Describes a PDF and draws small page images for the app's page panels. The app never opens the
/// PDF itself; the sandboxed worker does, and sends back only `info.json` and small PNGs
/// (see `PDFPreviewInfo`). Runs inside the worker.
enum PDFPreview {
    static func run(
        _ input: URL,
        password: String,
        thumbnailSide: Int,
        scratch: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> (outputs: [URL], result: ConversionResult) {
        guard let provider = CGDataProvider(url: input as CFURL), let document = CGPDFDocument(provider) else {
            throw ConversionError.unreadable
        }
        var locked = false
        if document.isEncrypted && !document.isUnlocked {
            // Most "locked" PDFs open with an empty user password; only then is a real one needed.
            if !document.unlockWithPassword("") && !(!password.isEmpty && document.unlockWithPassword(password)) {
                locked = true
            }
        }

        var info = PDFPreviewInfo(pageCount: 0, locked: locked, pages: [], thumbnailCount: 0)
        var images: [(name: String, url: URL)] = []
        if !locked {
            let count = document.numberOfPages
            guard count <= PDFPreviewInfo.maxPages else { throw ConversionError.dataLimit("more than \(PDFPreviewInfo.maxPages) pages") }
            info.pageCount = count
            info.pages = (0..<count).map { index in
                guard let page = document.page(at: index + 1) else { return .init(width: 1, height: 1, rotation: 0) }
                let size = uprightSize(page)
                return .init(width: size.width, height: size.height, rotation: Int(((page.rotationAngle % 360) + 360) % 360))
            }
            let side = min(max(thumbnailSide, PDFPreviewInfo.thumbnailSideRange.lowerBound), PDFPreviewInfo.thumbnailSideRange.upperBound)
            let wanted = thumbnailSide > 0 ? min(count, PDFPreviewInfo.maxThumbnails) : 0
            for number in stride(from: 1, through: wanted, by: 1) {
                guard let page = document.page(at: number) else { throw ConversionError.unreadable }
                let name = PDFPreviewInfo.thumbnailName(number)
                let url = scratch.appendingPathComponent(name)
                try thumbnail(of: page, side: side).write(to: url)
                images.append((name, url))
                progress(Double(number) / Double(wanted) * 0.95)
            }
            info.thumbnailCount = images.count
        }

        let infoURL = scratch.appendingPathComponent(PDFPreviewInfo.fileName)
        try JSONEncoder().encode(info).write(to: infoURL)
        let files = [(name: PDFPreviewInfo.fileName, url: infoURL)] + images
        progress(1)
        return (files.map(\.url), ConversionResult(outputBytes: 0, frames: info.pageCount, notes: [], outputNames: files.map(\.name)))
    }

    /// The page's crop box size after its rotation, never smaller than 1 point.
    static func uprightSize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let turned = ((page.rotationAngle % 360) + 360) % 360 / 90 % 2 == 1
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width.isFinite, size.height.isFinite else { return CGSize(width: 1, height: 1) }
        return CGSize(width: max(abs(size.width), 1), height: max(abs(size.height), 1))
    }

    /// One page as an opaque PNG whose longest side is `side` pixels.
    static func thumbnail(of page: CGPDFPage, side: Int) throws -> Data {
        let size = uprightSize(page)
        let scale = CGFloat(side) / max(size.width, size.height)
        let width = min(side, max(1, Int((size.width * scale).rounded())))
        let height = min(side, max(1, Int((size.height * scale).rounded())))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ConversionError.unreadable }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .medium
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)

        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw ConversionError.unreadable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.unreadable }
        return data as Data
    }
}
