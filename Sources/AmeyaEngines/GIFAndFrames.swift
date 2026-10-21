import AmeyaCore
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Video → GIF under a size ("GIF for chat, under 5 MB") and video → a folder of still pictures.
enum GIFAndFrames {
    typealias Job = MediaToolbox.Job

    /// One try at a GIF: picture size, frame rate and bits kept per colour channel.
    struct GIFPlan: Equatable {
        var longSide: Double
        var fps: Double
        var colourBits: Int

        static let first = GIFPlan(longSide: 480, fps: 12, colourBits: 8)

        /// The next, smaller plan from how far over the target the last one was.
        func next(ratio: Double, attempt: Int) -> GIFPlan {
            var plan = self
            let squeeze = min(max(ratio, 0.05), 0.95)
            // Bytes grow with the area and with the frame count; share the cut between them.
            if fps > 8, squeeze < 0.6 { plan.fps = max(8, fps * 0.75) }
            let remaining = squeeze * (fps / plan.fps)
            plan.longSide = max(96, (longSide * min(0.95, remaining.squareRoot() * 0.95)).rounded())
            if attempt >= 1 { plan.colourBits = max(3, colourBits - 1) }
            if plan.longSide <= 160 { plan.fps = max(5, plan.fps - 1) }
            return plan
        }
    }

    static func gif(_ input: URL, targetBytes: Int, job: Job) async throws -> [ConversionNote] {
        let asset = AVURLAsset(url: input)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw ConversionError.noVideoTrack }
        let duration = try await asset.load(.duration).seconds
        let length = min(duration, VideoConverter.gifMaxSeconds)
        var notes: [ConversionNote] = [.soundRemoved]
        if duration > VideoConverter.gifMaxSeconds { notes.append(.gifShortened) }

        var plan = GIFPlan.first
        var best: Data?
        let attempts = 7
        for attempt in 0..<attempts {
            let slice = job.slice(from: Double(attempt) / Double(attempts), to: Double(attempt + 1) / Double(attempts))
            let data = try await render(asset, seconds: length, plan: plan, progress: slice.progress)
            if best == nil || data.count < best!.count { best = data }
            if data.count <= targetBytes { break }
            plan = plan.next(ratio: Double(targetBytes) / Double(data.count), attempt: attempt)
        }
        guard let best else { throw ConversionError.encodeFailed(.gif) }
        try best.write(to: job.output)
        if plan != .first { notes.append(.gifFittedToSize) }
        if best.count > targetBytes { notes.append(.targetSizeNotReached) }
        return notes
    }

    static func render(_ asset: AVAsset, seconds: Double, plan: GIFPlan, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: plan.longSide, height: plan.longSide)
        let tolerance = CMTime(seconds: 0.5 / plan.fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let count = max(1, Int(seconds * plan.fps))
        var frames: [DecodedFrame] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            let time = CMTime(seconds: Double(index) / plan.fps, preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            frames.append(DecodedFrame(image: posterize(image, bits: plan.colourBits) ?? image, delay: 1 / plan.fps, metadata: [:]))
            progress(0.7 * Double(index + 1) / Double(count))
        }
        return try ImageConverter.encode(frames, as: .gif, animated: count > 1, loopCount: 0, quality: nil) { progress(0.7 + 0.3 * $0) }
    }

    /// Keeps only the top `bits` of each colour channel, so the GIF's palette holds fewer, more
    /// repeated colours and compresses further.
    static func posterize(_ image: CGImage, bits: Int) -> CGImage? {
        guard bits < 8 else { return nil }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
        let half = UInt8(1 << (7 - bits)) // round to the middle of each step
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for index in 0..<(width * height * 4) where index % 4 != 3 {
            pixels[index] = (pixels[index] & mask) | half
        }
        return context.makeImage()
    }

    // MARK: Frames

    /// Still pictures every `interval`, as PNG or JPEG files. Returns the files and their names.
    static func frames(
        _ input: URL, every interval: FrameInterval, format: FileFormat, maxFrames: Int, job: Job
    ) async throws -> ([URL], [String], [ConversionNote]) {
        guard format == .png || format == .jpeg else { throw ConversionError.unsupportedTarget(format) }
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ConversionError.noVideoTrack }
        let duration = try await asset.load(.duration).seconds
        let rate = Double(try await track.load(.nominalFrameRate))
        let step: Double = switch interval {
        case .everySeconds(let seconds): seconds
        case .everyFrames(let count): Double(count) / (rate > 0 ? rate : 30)
        }
        guard step > 0, step.isFinite else { throw ConversionError.refused("Choose a gap of more than zero between pictures.") }
        var times: [Double] = []
        var time = 0.0
        while time < duration - 0.001, times.count <= maxFrames {
            times.append(time)
            time += step
        }
        var notes: [ConversionNote] = []
        if times.count > maxFrames {
            times = Array(times.prefix(maxFrames))
            notes.append(.framesLimited)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let type = format == .png ? UTType.png : UTType.jpeg
        var urls: [URL] = []
        var names: [String] = []
        for (index, seconds) in times.enumerated() {
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 6000)).image
            let name = String(format: "frame %04d.%@", index + 1, format.preferredExtension)
            let url = job.scratch.appendingPathComponent("frame-\(index + 1).\(format.preferredExtension)")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw ConversionError.encodeFailed(format)
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodeFailed(format) }
            urls.append(url)
            names.append(name)
            job.progress(Double(index + 1) / Double(times.count))
        }
        return (urls, names, notes)
    }
}
