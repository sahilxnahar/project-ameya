import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO

/// Applies `ImageEdits` to decoded frames, and squeezes an encoded image under a byte target.
/// Frames arrive upright (EXIF orientation is already baked into the pixels by `ImageDecoder`).
enum ImageEditor {
    /// Crop, then rotate/flip, then resize, then the metadata policy, on every frame. Returns notes.
    static func apply(_ edits: ImageEdits, to frames: inout [DecodedFrame]) throws -> [ConversionNote] {
        var notes: [ConversionNote] = []
        let quarterTurns = try normalizedQuarterTurns(edits.rotation)
        var resized = false
        frames = try frames.map { frame in
            var frame = frame
            var image = frame.image
            if let crop = edits.crop { image = try cropped(image, to: crop) }
            if quarterTurns != 0 || edits.flipHorizontal || edits.flipVertical {
                image = try transformed(image, quarterTurns: quarterTurns,
                                        flipHorizontal: edits.flipHorizontal, flipVertical: edits.flipVertical)
            }
            if let limit = edits.maxPixelSize, max(image.width, image.height) > limit {
                guard limit > 0 else { throw ConversionError.invalidData("the size limit must be at least 1 pixel") }
                image = try scaled(image, by: Double(limit) / Double(max(image.width, image.height)))
                resized = true
            }
            if image !== frame.image { frame.metadata = dropStaleDimensions(frame.metadata) }
            frame.image = image
            frame.metadata = applyPolicy(edits.metadata, to: frame.metadata)
            return frame
        }
        if resized { notes.append(.resized) }
        switch edits.metadata {
        case .keep: break
        case .removeLocation: notes.append(.locationRemoved)
        case .removeAll: notes.append(.metadataRemoved)
        }
        return notes
    }

    static func normalizedQuarterTurns(_ degrees: Int) throws -> Int {
        guard degrees % 90 == 0 else { throw ConversionError.invalidData("rotation must be a multiple of 90°") }
        return ((degrees % 360) + 360) % 360 / 90
    }

    /// Crops to a unit rectangle (origin top-left) of the upright image.
    static func cropped(_ image: CGImage, to rect: UnitRect) throws -> CGImage {
        let clamp = { (value: Double) in min(max(value, 0), 1) }
        let left = clamp(rect.x), top = clamp(rect.y)
        let right = clamp(rect.x + rect.width), bottom = clamp(rect.y + rect.height)
        let pixels = CGRect(
            x: (left * Double(image.width)).rounded(),
            y: (top * Double(image.height)).rounded(),
            width: ((right - left) * Double(image.width)).rounded(),
            height: ((bottom - top) * Double(image.height)).rounded()
        )
        // CGImage cropping uses the image's own top-left pixel grid.
        guard pixels.width >= 1, pixels.height >= 1, let result = image.cropping(to: pixels) else {
            throw ConversionError.invalidData("the crop area is empty")
        }
        return result
    }

    /// Rotates clockwise by quarter turns, then mirrors, in one redraw.
    static func transformed(_ image: CGImage, quarterTurns: Int, flipHorizontal: Bool, flipVertical: Bool) throws -> CGImage {
        let swap = quarterTurns % 2 == 1
        let width = swap ? image.height : image.width
        let height = swap ? image.width : image.height
        let context = try makeContext(width: width, height: height, like: image)
        // Core Graphics has a bottom-left origin; the last transform added applies to the image first.
        if flipHorizontal {
            context.translateBy(x: CGFloat(width), y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        if flipVertical {
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
        }
        switch quarterTurns {
        case 1: // 90° clockwise
            context.translateBy(x: 0, y: CGFloat(height))
            context.rotate(by: -.pi / 2)
        case 2:
            context.translateBy(x: CGFloat(width), y: CGFloat(height))
            context.rotate(by: .pi)
        case 3: // 90° counter-clockwise
            context.translateBy(x: CGFloat(width), y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw ConversionError.encodeFailed(.png) }
        return result
    }

    /// High-quality downscale by `factor` (≤ 1). Never enlarges.
    static func scaled(_ image: CGImage, by factor: Double) throws -> CGImage {
        let factor = min(factor, 1)
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard width != image.width || height != image.height else { return image }
        let context = try makeContext(width: width, height: height, like: image)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ConversionError.encodeFailed(.png) }
        return result
    }

    private static func makeContext(width: Int, height: Int, like image: CGImage) throws -> CGContext {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let alpha = image.hasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: alpha.rawValue)
            ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue) else {
            throw ConversionError.tooLarge(pixels: width * height, limit: width * height)
        }
        return context
    }

    /// EXIF pixel dimensions describe the old geometry; ImageIO fills in the right values.
    private static func dropStaleDimensions(_ metadata: [CFString: Any]) -> [CFString: Any] {
        var metadata = metadata
        if var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        return metadata
    }

    /// `removeLocation` drops the GPS dictionary; `removeAll` keeps only resolution and orientation.
    static func applyPolicy(_ policy: MetadataPolicy, to metadata: [CFString: Any]) -> [CFString: Any] {
        switch policy {
        case .keep:
            return metadata
        case .removeLocation:
            var metadata = metadata
            metadata[kCGImagePropertyGPSDictionary] = nil
            return metadata
        case .removeAll:
            return metadata.filter { key, _ in
                key == kCGImagePropertyDPIWidth || key == kCGImagePropertyDPIHeight || key == kCGImagePropertyOrientation
            }
        }
    }

    // MARK: Byte target

    /// Encodes so the result is at most `targetBytes`, if possible.
    ///
    /// Lossy targets: binary-search quality between 0.95 and 0.1 in at most 7 encodes, then shrink
    /// the pixels by ×0.8 up to 5 times. Lossless targets: shrink only. If the target still isn't
    /// met, the smallest attempt is returned with `.targetSizeNotReached`.
    static func encode(
        _ frames: [DecodedFrame],
        within targetBytes: Int,
        lossy: Bool,
        encode: ([DecodedFrame], Double?) throws -> Data
    ) throws -> (Data, [ConversionNote]) {
        guard targetBytes > 0 else { throw ConversionError.invalidData("the size target must be above zero") }
        var smallest: Data?
        func consider(_ data: Data) -> Data? {
            if smallest == nil || data.count < smallest!.count { smallest = data }
            return data.count <= targetBytes ? data : nil
        }

        if lossy {
            if let fits = consider(try encode(frames, 0.95)) { return (fits, []) }
            if consider(try encode(frames, 0.1)) != nil {
                var low = 0.1, high = 0.95
                var best = smallest!
                for _ in 0..<5 {
                    let middle = (low + high) / 2
                    let data = try encode(frames, middle)
                    if consider(data) != nil { best = data; low = middle } else { high = middle }
                }
                return (best, [])
            }
        } else if let fits = consider(try encode(frames, nil)) {
            return (fits, [])
        }

        var current = frames
        for _ in 0..<5 {
            current = try current.map { frame in
                var frame = frame
                frame.image = try scaled(frame.image, by: 0.8)
                return frame
            }
            let qualities: [Double?] = lossy ? [0.6, 0.3, 0.1] : [nil]
            for quality in qualities {
                if let fits = consider(try encode(current, quality)) { return (fits, [.resized]) }
            }
        }
        return (smallest!, [.resized, .targetSizeNotReached])
    }
}
