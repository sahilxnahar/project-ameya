import AmeyaCore
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Video re-encoding (MP4, MOV, M4V), video → GIF and GIF → video, using AVFoundation
/// and the Mac's hardware encoders.
enum VideoConverter {
    static let gifFrameRate = 12.0
    static let gifMaxSeconds = 30.0
    static let gifMaxDimension = 480.0

    static func fileType(for format: FileFormat) -> AVFileType? {
        switch format {
        case .mp4: .mp4
        case .mov: .mov
        case .m4v: .m4v
        default: nil
        }
    }

    // MARK: Video → video

    static func transcode(input: URL, to target: FileFormat, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: input)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw ConversionError.noVideoTrack }
        guard let fileType = fileType(for: target),
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ConversionError.unsupportedTarget(target)
        }
        guard session.supportedFileTypes.contains(fileType) else { throw ConversionError.unsupportedTarget(target) }
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true

        let box = SessionBox(session)
        let poller = Task {
            while !Task.isCancelled {
                progress(Double(box.session.progress) * 0.99)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { poller.cancel() }
        await box.session.export()

        guard box.session.status == .completed else {
            throw ConversionError.mediaFailed(box.session.error?.localizedDescription ?? "the video couldn't be exported")
        }
        progress(1)
    }

    // MARK: Video → GIF

    static func toGIF(input: URL, progress: (Double) -> Void) async throws -> (Data, [ConversionNote]) {
        let asset = AVURLAsset(url: input)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw ConversionError.noVideoTrack }
        let duration = try await asset.load(.duration).seconds
        let length = min(duration, gifMaxSeconds)
        var notes: [ConversionNote] = [.soundRemoved]
        if duration > gifMaxSeconds { notes.append(.gifShortened) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: gifMaxDimension, height: gifMaxDimension)
        let tolerance = CMTime(seconds: 0.5 / gifFrameRate, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let count = max(1, Int(length * gifFrameRate))
        var frames: [DecodedFrame] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            let time = CMTime(seconds: Double(index) / gifFrameRate, preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            frames.append(DecodedFrame(image: image, delay: 1 / gifFrameRate, metadata: [:]))
            progress(0.8 * Double(index + 1) / Double(count))
        }
        let data = try ImageConverter.encode(frames, as: .gif, animated: count > 1, loopCount: 0, quality: nil) { fraction in
            progress(0.8 + 0.2 * fraction)
        }
        return (data, notes)
    }

    // MARK: GIF → video

    static func gifToVideo(_ data: Data, to target: FileFormat, output: URL, options: ConversionOptions, progress: (Double) -> Void) async throws -> [ConversionNote] {
        guard let fileType = fileType(for: target) else { throw ConversionError.unsupportedTarget(target) }
        let decoded = try ImageDecoder.decode(data, options: options)
        guard let first = decoded.frames.first else { throw ConversionError.unreadable }
        // H.264 needs even dimensions.
        let width = max(2, first.image.width & ~1)
        let height = max(2, first.image.height & ~1)

        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw ConversionError.unsupportedTarget(target) }
        writer.add(input)
        guard writer.startWriting() else {
            throw ConversionError.mediaFailed(writer.error?.localizedDescription ?? "couldn't start writing")
        }
        writer.startSession(atSourceTime: .zero)

        var seconds = 0.0
        for (index, frame) in decoded.frames.enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool, let buffer = try makePixelBuffer(from: frame.image, pool: pool, width: width, height: height) else {
                throw ConversionError.mediaFailed("couldn't prepare a video frame")
            }
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600))
            // A still image becomes a two-second clip; animation frames keep their own timing.
            seconds += decoded.frames.count == 1 ? 2 : max(frame.delay ?? 0.1, 0.02)
            progress(0.95 * Double(index + 1) / Double(decoded.frames.count))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ConversionError.mediaFailed(writer.error?.localizedDescription ?? "the video couldn't be written")
        }
        progress(1)
        return decoded.frames.contains(where: { $0.image.hasTransparentPixels }) ? [.transparencyFilledWhite] : []
    }

    private static func makePixelBuffer(from image: CGImage, pool: CVPixelBufferPool, width: Int, height: Int) throws -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return buffer
    }
}

/// AVAssetExportSession isn't Sendable; the progress poller only reads `progress`, which is thread-safe.
private final class SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
