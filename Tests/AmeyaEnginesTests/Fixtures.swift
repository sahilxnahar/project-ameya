import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO

/// Builds test images in memory so the suite needs no binary fixture files.
enum Fixtures {
    static func context(width: Int = 64, height: Int = 48) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }

    /// 64×48, left half fully transparent, right half opaque orange.
    static func halfTransparent() -> CGImage {
        let context = context()
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 48))
        return context.makeImage()!
    }

    /// Opaque frames in different colours, for animations and multi-page files.
    static func frames(_ count: Int) -> [CGImage] {
        (0..<count).map { index in
            let context = context()
            let shade = CGFloat(index) / CGFloat(max(count - 1, 1))
            context.setFillColor(CGColor(red: shade, green: 0.5, blue: 1 - shade, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            return context.makeImage()!
        }
    }

    static func encode(_ images: [CGImage], as format: FileFormat, delay: Double? = nil, orientation: Int? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.typeIdentifier as CFString, images.count, nil) else {
            throw CocoaError(.featureUnsupported)
        }
        for image in images {
            var properties: [CFString: Any] = [:]
            if let delay, format == .gif {
                properties[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: delay]
            }
            if let orientation {
                properties[kCGImagePropertyOrientation] = orientation
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    static func decode(_ data: Data) -> [CGImage]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let images = (0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
        return images.isEmpty ? nil : images
    }

    static func pageCount(_ pdf: Data) -> Int {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider) else { return 0 }
        return document.numberOfPages
    }

    /// RGB of one pixel (origin top-left), drawn into a known sRGB buffer so the result is independent of the source layout.
    static func pixel(of image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8)? {
        var buffer = [UInt8](repeating: 0, count: 4)
        let drawn = buffer.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
            return true
        }
        return drawn ? (buffer[0], buffer[1], buffer[2]) : nil
    }
}
