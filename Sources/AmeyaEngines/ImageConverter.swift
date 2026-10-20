import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO

public enum ConversionError: Error, Equatable, LocalizedError {
    case unreadable
    case unsupportedTarget(FileFormat)
    case tooLarge(pixels: Int, limit: Int)
    case lockedPDF
    case encodeFailed(FileFormat)

    public var errorDescription: String? {
        switch self {
        case .unreadable: "This file couldn't be read. It may be damaged or not an image."
        case .unsupportedTarget(let format): "This Mac can't create \(format.displayName) files."
        case .tooLarge(let pixels, let limit): "The image is too large (\(pixels / 1_000_000) MP, limit \(limit / 1_000_000) MP)."
        case .lockedPDF: "This PDF is password-protected."
        case .encodeFailed(let format): "Couldn't write the \(format.displayName) file."
        }
    }
}

/// Converts between still, animated and multi-page images, and PDF pages.
public enum ImageConverter {
    public static func convert(
        _ data: Data,
        request: ConversionRequest,
        progress: (Double) -> Void = { _ in }
    ) throws -> (Data, ConversionResult) {
        let decoded = try ImageDecoder.decode(data, options: request.options)
        progress(0.4)
        let target = request.target
        var notes: [ConversionNote] = []

        // Decide which frames survive in the target format.
        var frames = decoded.frames
        if frames.count > 1 {
            switch decoded.kind {
            case .animated where target.supportsAnimation:
                break
            case .animated where target.supportsPages:
                notes.append(.animationBecamePages)
            case .paged where target.supportsPages:
                break
            case .animated:
                frames = [frames[0]]
                notes.append(.onlyFirstFrameKept)
            case .paged, .single:
                frames = [frames[0]]
                notes.append(.onlyFirstPageKept)
            }
        }

        if !target.supportsAlpha && frames.contains(where: { $0.image.hasAlpha }) {
            frames = try frames.map { frame in
                var flat = frame
                flat.image = try flattenOnWhite(frame.image)
                return flat
            }
            notes.append(.transparencyFilledWhite)
        }

        let output: Data
        if target == .pdf {
            output = try PDFWriter.write(frames)
        } else {
            let animated = decoded.kind == .animated && target.supportsAnimation && frames.count > 1
            output = try encode(frames, as: target, animated: animated, loopCount: decoded.loopCount, quality: request.options.quality) { fraction in
                progress(0.4 + 0.6 * fraction)
            }
        }
        progress(1)
        return (output, ConversionResult(outputBytes: output.count, frames: frames.count, notes: notes))
    }

    static func encode(
        _ frames: [DecodedFrame],
        as target: FileFormat,
        animated: Bool,
        loopCount: Int,
        quality: Double?,
        progress: (Double) -> Void
    ) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, target.typeIdentifier as CFString, frames.count, nil
        ) else {
            throw ConversionError.unsupportedTarget(target)
        }

        if animated {
            let container: [CFString: Any] = switch target {
            case .gif: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]]
            case .png: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: loopCount]]
            default: [:]
            }
            CGImageDestinationSetProperties(destination, container as CFDictionary)
        }

        for (index, frame) in frames.enumerated() {
            var properties = frame.metadata
            if target.isLossy {
                properties[kCGImageDestinationLossyCompressionQuality] = quality ?? 0.85
            }
            if animated, let delay = frame.delay {
                switch target {
                case .gif: properties[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: delay]
                case .png: properties[kCGImagePropertyPNGDictionary] = [kCGImagePropertyAPNGDelayTime: delay]
                default: break
                }
            }
            CGImageDestinationAddImage(destination, frame.image, properties as CFDictionary)
            progress(Double(index + 1) / Double(frames.count))
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.encodeFailed(target)
        }
        return output as Data
    }

    static func flattenOnWhite(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ConversionError.encodeFailed(.jpeg)
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let flat = context.makeImage() else { throw ConversionError.encodeFailed(.jpeg) }
        return flat
    }
}

extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}
