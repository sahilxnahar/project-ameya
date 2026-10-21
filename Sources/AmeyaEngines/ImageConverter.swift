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
    case unsupportedConversion(from: FileFormat, to: FileFormat)
    case noText
    case noAudioTrack
    case noVideoTrack
    case noSubtitles
    case mediaFailed(String)
    case invalidData(String)
    case dataLimit(String)
    /// A tool that exists in the request format but has no engine yet, e.g. "Making PDFs smaller".
    case notAvailableYet(String)
    /// The photo can't be used for this tool; the text says why and what to do instead.
    case needsDifferentPhoto(String)
    /// A size target or edit that can't work, e.g. a two-hour video into 8 MB. The text is a full,
    /// friendly sentence that says what to do instead.
    case cannotFit(String)
    /// The password given for a PDF doesn't open it.
    case wrongPassword
    /// The tool can't or needn't run on this file; the message says why in full.
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .needsDifferentPhoto(let advice): advice
        case .cannotFit(let advice): advice
        case .notAvailableYet(let feature): "\(feature) isn't available yet."
        case .unsupportedConversion(let from, let to): "Ameya can't convert \(from.displayName) to \(to.displayName) yet."
        case .noText: "No text was found, and none could be recognised in the pages or pictures."
        case .wrongPassword: "That password isn't right for this PDF."
        case .refused(let reason): reason
        case .noAudioTrack: "This file has no sound to convert."
        case .noVideoTrack: "This file has no video."
        case .noSubtitles: "No subtitles were found in this file."
        case .mediaFailed(let reason): "The conversion failed: \(reason)"
        case .invalidData(let reason): "This file couldn't be read: \(reason)."
        case .dataLimit(let reason): "This file is too big to convert: \(reason)."
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
        let target = request.target
        var notes: [ConversionNote] = []
        let decoded: DecodedImage
        if request.source == .svg || (request.source == nil && SVGRenderer.looksLikeSVG(data)) {
            if target == .pdf { // drawn straight into the PDF so it stays vector
                let (pdf, svgNotes) = try SVGRenderer.pdf(data, options: request.options)
                progress(1)
                return (pdf, ConversionResult(outputBytes: pdf.count, frames: 1, notes: svgNotes))
            }
            (decoded, notes) = try SVGRenderer.decode(data, options: request.options)
        } else {
            decoded = try ImageDecoder.decode(data, options: request.options)
        }
        progress(0.4)

        // Decide which frames survive in the target format.
        var frames = decoded.frames
        let edits = request.options.image ?? ImageEdits()
        if !edits.isIdentity {
            notes += try ImageEditor.apply(edits, to: &frames)
        }
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

        // Flatten whenever an alpha channel exists, but only say so if something was really see-through.
        if !target.supportsAlpha && frames.contains(where: { $0.image.hasAlpha }) {
            let transparent = frames.contains(where: { $0.image.hasTransparentPixels })
            frames = try frames.map { frame in
                var flat = frame
                flat.image = try flattenOnWhite(frame.image)
                return flat
            }
            if transparent { notes.append(.transparencyFilledWhite) }
        }

        if target.isIcon {
            frames = try iconSizes(for: target, fitting: frames[0].image).map { side in
                DecodedFrame(image: try squareIcon(frames[0].image, side: side), delay: nil, metadata: [:])
            }
            notes = [.madeSquareIcon]
        }

        let output: Data
        if target == .pdf {
            output = try PDFWriter.write(frames)
        } else if let targetBytes = edits.targetBytes, !target.isIcon {
            let animated = decoded.kind == .animated && target.supportsAnimation && frames.count > 1
            let sizeNotes: [ConversionNote]
            (output, sizeNotes) = try ImageEditor.encode(frames, within: targetBytes, lossy: target.isLossy) { attempt, quality in
                try encode(attempt, as: target, animated: animated, loopCount: decoded.loopCount,
                           quality: quality ?? request.options.quality) { _ in }
            }
            notes += sizeNotes.filter { !notes.contains($0) }
        } else {
            let animated = decoded.kind == .animated && target.supportsAnimation && frames.count > 1
            // WebP: lossless for sources that were lossless, unless the user picked a quality.
            let losslessSource: Set<FileFormat> = [.png, .tiff, .bmp, .gif]
            let lossless = request.options.quality == nil && FileFormat.sniff(data.prefix(32)).map(losslessSource.contains) == true
            output = try encode(
                frames, as: target, animated: animated, loopCount: decoded.loopCount,
                quality: request.options.quality, lossless: lossless
            ) { fraction in
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
        lossless: Bool = false,
        progress: (Double) -> Void
    ) throws -> Data {
        if target == .webp {
            return try WebPEncoder.encode(
                frames, animated: animated, loopCount: loopCount, quality: quality, lossless: lossless, progress: progress
            )
        }
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

    /// Standard icon sizes up to the image's larger side (always at least the smallest one).
    static func iconSizes(for target: FileFormat, fitting image: CGImage) throws -> [Int] {
        // ICNS has no 64 px slot (64 px appears only as 32 px @2x, which needs the 32 px image).
        let standard = target == .icns ? [16, 32, 128, 256, 512, 1024] : [16, 24, 32, 48, 64, 128, 256]
        let largest = max(image.width, image.height)
        let sizes = standard.filter { $0 <= largest }
        return sizes.isEmpty ? [standard[0]] : sizes
    }

    /// The image scaled to fit a transparent square, centred.
    static func squareIcon(_ image: CGImage, side: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ConversionError.encodeFailed(.ico) }
        let scale = Double(side) / Double(max(image.width, image.height))
        let width = Double(image.width) * scale
        let height = Double(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (Double(side) - width) / 2, y: (Double(side) - height) / 2, width: width, height: height))
        guard let icon = context.makeImage() else { throw ConversionError.encodeFailed(.ico) }
        return icon
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
    /// True only if some pixel is not fully opaque. Decoders often attach an alpha channel to photos
    /// that are completely opaque, so the channel alone proves nothing. Scans a ≤ 256 px copy.
    var hasTransparentPixels: Bool {
        guard hasAlpha else { return false }
        let scale = min(1, 256 / Double(max(width, height)))
        let w = max(1, Int((Double(width) * scale).rounded()))
        let h = max(1, Int((Double(height) * scale).rounded()))
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buffer.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high // averages alpha, so thin transparent areas still show up
            context.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        // If the scan couldn't run, assume the worst so the note is never hidden wrongly.
        guard drawn else { return true }
        var index = 3
        while index < buffer.count {
            if buffer[index] != 255 { return true }
            index += 4
        }
        return false
    }

    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}
