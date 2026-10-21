import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO

/// A 4×6 in (10×15 cm) print sheet tiled with as many copies of a passport photo as fit, with thin
/// cut guides, as a 300 dpi JPEG and a PDF of the exact paper size.
enum PassportSheet {
    static let dpi = 300.0

    static func make(photo: CGImage, spec: PassportSpec) throws -> (jpeg: Data, pdf: Data) {
        let layout = PassportGeometry.sheetLayout(photoWidthMM: spec.widthMM, photoHeightMM: spec.heightMM)
        guard layout.count > 0 else {
            throw ConversionError.needsDifferentPhoto("This photo size is too big for a 4×6 in print sheet.")
        }
        let width = PassportGeometry.pixels(mm: layout.sheetWidthMM, dpi: dpi)
        let height = PassportGeometry.pixels(mm: layout.sheetHeightMM, dpi: dpi)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ConversionError.encodeFailed(.jpeg) }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high

        let frames = PassportGeometry.sheetFrames(layout, photoWidthMM: spec.widthMM, photoHeightMM: spec.heightMM, dpi: dpi)
        // Frames are top-left based; Core Graphics draws bottom-up.
        let rects = frames.map { CGRect(x: $0.x, y: Double(height) - $0.y - $0.height, width: $0.width, height: $0.height) }
        for rect in rects { context.draw(photo, in: rect) }
        context.setStrokeColor(CGColor(gray: 0.65, alpha: 1))
        context.setLineWidth(1)
        for rect in rects { context.stroke(rect.insetBy(dx: -0.5, dy: -0.5)) }
        guard let sheet = context.makeImage() else { throw ConversionError.encodeFailed(.jpeg) }

        let jpeg = try ImageConverter.encode(
            [DecodedFrame(image: sheet, delay: nil, metadata: [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi])],
            as: .jpeg, animated: false, loopCount: 0, quality: 0.92
        ) { _ in }
        return (jpeg, try pdf(jpeg, widthMM: layout.sheetWidthMM, heightMM: layout.sheetHeightMM))
    }

    /// One page of the paper's size showing the sheet. Drawing the JPEG-backed image lets the PDF
    /// keep the JPEG data rather than re-compressing it.
    static func pdf(_ jpeg: Data, widthMM: Double, heightMM: Double) throws -> Data {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ConversionError.encodeFailed(.pdf) }
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: widthMM / 25.4 * 72, height: heightMM / 25.4 * 72)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw ConversionError.encodeFailed(.pdf) }
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }
}
