import Accelerate
import AmeyaCore
import CWebP
import CoreGraphics
import Foundation

/// Writes still and animated WebP with the vendored libwebp, because ImageIO can read WebP but not write it.
///
/// Compression rule: lossless when `lossless` is true (the caller passes true for PNG, TIFF, BMP and GIF
/// sources when the user hasn't chosen a quality), lossy at `quality` (0...1, default 0.85 → q85) otherwise.
/// Alpha is always kept. Metadata (EXIF, XMP, ICC) is not written yet.
enum WebPEncoder {
    /// WebP's hard limit on either side.
    static let maxDimension = 16_383

    static func encode(
        _ frames: [DecodedFrame],
        animated: Bool,
        loopCount: Int,
        quality: Double?,
        lossless: Bool,
        progress: (Double) -> Void = { _ in }
    ) throws -> Data {
        guard let first = frames.first else { throw ConversionError.encodeFailed(.webp) }
        for frame in frames where frame.image.width > maxDimension || frame.image.height > maxDimension {
            throw ConversionError.mediaFailed(
                "WebP images can be at most \(maxDimension) pixels wide or tall (this one is \(frame.image.width)×\(frame.image.height))."
            )
        }

        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { throw ConversionError.encodeFailed(.webp) }
        if lossless {
            config.lossless = 1
            config.quality = 75 // effort, not fidelity, in lossless mode
        } else {
            config.quality = Float(min(max(quality ?? 0.85, 0), 1) * 100)
        }
        config.method = 4
        guard WebPValidateConfig(&config) != 0 else { throw ConversionError.encodeFailed(.webp) }

        if animated && frames.count > 1 {
            return try encodeAnimation(frames, config: &config, loopCount: loopCount, progress: progress)
        }
        let output = try encodeStill(first.image, config: &config)
        progress(1)
        return output
    }

    // MARK: - Still

    private static func encodeStill(_ image: CGImage, config: inout WebPConfig) throws -> Data {
        var picture = try makePicture(image, lossless: config.lossless != 0)
        defer { WebPPictureFree(&picture) }

        let writer = UnsafeMutablePointer<WebPMemoryWriter>.allocate(capacity: 1)
        WebPMemoryWriterInit(writer)
        defer {
            WebPMemoryWriterClear(writer)
            writer.deallocate()
        }
        picture.writer = WebPMemoryWrite
        picture.custom_ptr = UnsafeMutableRawPointer(writer)

        guard WebPEncode(&config, &picture) != 0, let bytes = writer.pointee.mem else {
            throw ConversionError.encodeFailed(.webp)
        }
        return Data(bytes: bytes, count: writer.pointee.size)
    }

    // MARK: - Animation

    private static func encodeAnimation(
        _ frames: [DecodedFrame],
        config: inout WebPConfig,
        loopCount: Int,
        progress: (Double) -> Void
    ) throws -> Data {
        let width = frames.map(\.image.width).max() ?? 0
        let height = frames.map(\.image.height).max() ?? 0

        var options = WebPAnimEncoderOptions()
        guard WebPAnimEncoderOptionsInit(&options) != 0 else { throw ConversionError.encodeFailed(.webp) }
        options.anim_params.loop_count = Int32(clamping: max(loopCount, 0))
        options.anim_params.bgcolor = 0x0000_0000 // transparent

        guard let encoder = WebPAnimEncoderNew(Int32(width), Int32(height), &options) else {
            throw ConversionError.encodeFailed(.webp)
        }
        defer { WebPAnimEncoderDelete(encoder) }

        var timestamp = 0 // milliseconds
        for (index, frame) in frames.enumerated() {
            // Frames smaller than the canvas are drawn at its top-left, as GIF and APNG decoders give them to us.
            let image = frame.image.width == width && frame.image.height == height
                ? frame.image
                : try padded(frame.image, width: width, height: height)
            var picture = try makePicture(image, lossless: config.lossless != 0)
            defer { WebPPictureFree(&picture) }
            guard WebPAnimEncoderAdd(encoder, &picture, Int32(clamping: timestamp), &config) != 0 else {
                throw ConversionError.encodeFailed(.webp)
            }
            timestamp += max(Int(((frame.delay ?? 0.1) * 1000).rounded()), 1)
            progress(Double(index + 1) / Double(frames.count) * 0.95)
        }
        // A final empty frame sets the last frame's duration.
        guard WebPAnimEncoderAdd(encoder, nil, Int32(clamping: timestamp), nil) != 0 else {
            throw ConversionError.encodeFailed(.webp)
        }

        var assembled = WebPData()
        WebPDataInit(&assembled)
        defer { WebPDataClear(&assembled) }
        guard WebPAnimEncoderAssemble(encoder, &assembled) != 0, let bytes = assembled.bytes else {
            throw ConversionError.encodeFailed(.webp)
        }
        progress(1)
        return Data(bytes: bytes, count: assembled.size)
    }

    // MARK: - Pixels

    /// A WebPPicture holding the image as straight (non-premultiplied) sRGB RGBA, which is what libwebp expects.
    private static func makePicture(_ image: CGImage, lossless: Bool) throws -> WebPPicture {
        var rgba = try straightRGBA(image)
        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { throw ConversionError.encodeFailed(.webp) }
        picture.width = Int32(image.width)
        picture.height = Int32(image.height)
        picture.use_argb = lossless ? 1 : 0
        let imported = rgba.bytes.withUnsafeMutableBufferPointer { buffer in
            WebPPictureImportRGBA(&picture, buffer.baseAddress, Int32(rgba.bytesPerRow))
        }
        guard imported != 0 else {
            WebPPictureFree(&picture)
            throw ConversionError.encodeFailed(.webp)
        }
        return picture
    }

    private static func straightRGBA(_ image: CGImage) throws -> (bytes: [UInt8], bytesPerRow: Int) {
        let width = image.width, height = image.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // Core Graphics only renders premultiplied alpha; undo it in place.
            var buffer = vImage_Buffer(
                data: raw.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow
            )
            return vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        guard ok else { throw ConversionError.encodeFailed(.webp) }
        return (bytes, bytesPerRow)
    }

    private static func padded(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ConversionError.encodeFailed(.webp) }
        context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw ConversionError.encodeFailed(.webp) }
        return result
    }
}
