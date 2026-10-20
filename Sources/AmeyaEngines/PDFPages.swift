import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO

/// Renders PDF pages to images.
enum PDFRasterizer {
    /// Pages render at 144 dpi (2× screen points) unless that would exceed the pixel limit.
    static let preferredScale: CGFloat = 2

    static func rasterize(_ data: Data, options: ConversionOptions) throws -> DecodedImage {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages > 0 else {
            throw ConversionError.unreadable
        }
        if document.isEncrypted && !document.isUnlocked && !document.unlockWithPassword("") {
            throw ConversionError.lockedPDF
        }

        let pageCount = min(document.numberOfPages, options.maxFrames)
        let frames = try (1...pageCount).map { number -> DecodedFrame in
            guard let page = document.page(at: number) else { throw ConversionError.unreadable }
            return try render(page, maxPixels: options.maxPixels)
        }
        return DecodedImage(frames: frames, kind: pageCount > 1 ? .paged : .single, loopCount: 0)
    }

    private static func render(_ page: CGPDFPage, maxPixels: Int) throws -> DecodedFrame {
        let box = page.getBoxRect(.cropBox)
        let quarterTurns = ((page.rotationAngle % 360) + 360) % 360 / 90
        let size = quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width >= 1, size.height >= 1 else { throw ConversionError.unreadable }

        var scale = preferredScale
        let pixelsAtScale = Double(size.width * scale) * Double(size.height * scale)
        if pixelsAtScale > Double(maxPixels) {
            scale *= CGFloat((Double(maxPixels) / pixelsAtScale).squareRoot())
        }
        let width = max(1, Int(size.width * scale))
        let height = max(1, Int(size.height * scale))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ConversionError.tooLarge(pixels: width * height, limit: maxPixels)
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        // getDrawingTransform handles the crop box origin and page rotation. It never scales up,
        // which is why the context itself is scaled above.
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)

        guard let image = context.makeImage() else { throw ConversionError.unreadable }
        let dpi = 72 * scale
        return DecodedFrame(image: image, delay: nil, metadata: [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ])
    }
}

/// Writes images as PDF pages, one page per frame, sized from each image's resolution.
enum PDFWriter {
    static func write(_ frames: [DecodedFrame]) throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ConversionError.encodeFailed(.pdf)
        }
        for frame in frames {
            let dpi = (frame.metadata[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
            var mediaBox = CGRect(
                x: 0, y: 0,
                width: Double(frame.image.width) * 72 / dpi,
                height: Double(frame.image.height) * 72 / dpi
            )
            context.beginPage(mediaBox: &mediaBox)
            context.draw(frame.image, in: mediaBox)
            context.endPage()
        }
        context.closePDF()
        return output as Data
    }
}
