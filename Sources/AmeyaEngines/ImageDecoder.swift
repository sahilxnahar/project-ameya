import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO

struct DecodedFrame {
    var image: CGImage
    /// Seconds this frame is shown, for animations.
    var delay: Double?
    /// EXIF, GPS, IPTC, TIFF and DPI metadata to carry over. Orientation is already applied to the pixels.
    var metadata: [CFString: Any]
}

struct DecodedImage {
    enum Kind { case single, animated, paged }

    var frames: [DecodedFrame]
    var kind: Kind
    var loopCount: Int
}

enum ImageDecoder {
    static func decode(_ data: Data, options: ConversionOptions) throws -> DecodedImage {
        if FileFormat.sniff(data.prefix(32)) == .pdf {
            return try PDFRasterizer.rasterize(data, options: options)
        }
        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) > 0 else {
            throw ConversionError.unreadable
        }

        let count = CGImageSourceGetCount(source)
        let type = CGImageSourceGetType(source) as String? ?? ""
        let animatedTypes: Set<String> = [FileFormat.gif, .png, .webp].map(\.typeIdentifier).reduce(into: []) { $0.insert($1) }
        let kind: DecodedImage.Kind = if count > 1 && animatedTypes.contains(type) {
            .animated
        } else if count > 1 && type == FileFormat.tiff.typeIdentifier {
            .paged
        } else {
            .single
        }

        let indices: [Int] = kind == .single
            ? [CGImageSourceGetPrimaryImageIndex(source)]
            : Array(0..<min(count, options.maxFrames))
        try checkTotalPixels(source, indices: indices, options: options)
        let frames = try indices.map { try decodeFrame(source, at: $0, maxPixels: options.maxPixels) }
        return DecodedImage(frames: frames, kind: kind, loopCount: loopCount(of: source))
    }

    /// Every frame is held in memory until the output is written, so the declared sizes of all
    /// of them together are checked before any is decoded: a small file can't claim a thousand
    /// frames of 100 megapixels each.
    private static func checkTotalPixels(_ source: CGImageSource, indices: [Int], options: ConversionOptions) throws {
        let budget = options.totalPixelBudget
        var total = 0
        for index in indices {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { continue } // decodeFrame refuses it
            let (pixels, overflow) = max(width, 0).multipliedReportingOverflow(by: max(height, 0))
            let (sum, sumOverflow) = total.addingReportingOverflow(pixels)
            guard !overflow, !sumOverflow, sum <= budget else {
                throw ConversionError.tooLarge(pixels: overflow || sumOverflow ? Int.max : sum, limit: budget)
            }
            total = sum
        }
    }

    private static func decodeFrame(_ source: CGImageSource, at index: Int, maxPixels: Int) throws -> DecodedFrame {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ConversionError.unreadable
        }
        // Check the declared size before decoding anything, so a tiny file can't claim gigapixels.
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxPixels else {
            throw ConversionError.tooLarge(pixels: overflow ? Int.max : pixels, limit: maxPixels)
        }

        // A full-size "thumbnail" with the transform applied bakes EXIF orientation into the pixels,
        // so every viewer shows the output the same way up.
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, decodeOptions as CFDictionary) else {
            throw ConversionError.unreadable
        }
        return DecodedFrame(image: image, delay: delay(in: properties), metadata: carriedMetadata(properties))
    }

    private static func carriedMetadata(_ properties: [CFString: Any]) -> [CFString: Any] {
        var metadata: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = properties[key] { metadata[key] = value }
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        metadata[kCGImagePropertyOrientation] = 1
        return metadata
    }

    private static func delay(in properties: [CFString: Any]) -> Double? {
        let candidates: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dictionaryKey, unclamped, clamped) in candidates {
            guard let dictionary = properties[dictionaryKey] as? [CFString: Any] else { continue }
            if let value = (dictionary[unclamped] as? Double) ?? (dictionary[clamped] as? Double), value > 0 {
                return value
            }
        }
        return nil
    }

    private static func loopCount(of source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        if let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
           let loops = gif[kCGImagePropertyGIFLoopCount] as? Int {
            return loops
        }
        if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
           let loops = png[kCGImagePropertyAPNGLoopCount] as? Int {
            return loops
        }
        return 0 // loop forever
    }
}
