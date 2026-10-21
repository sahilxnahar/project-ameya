import AmeyaCore
@preconcurrency import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
@testable import AmeyaEngines

/// Generated media for the size-preset tests: busy, moving content so bitrates and byte targets matter.
enum PresetMedia {
    /// One shared 10 s, 1920×1080, 30 fps H.264 clip (~30 Mbit/s) with a tone, made once per test run.
    static let shared = Task<URL, Error> {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-busy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try await makeBusyClip(in: directory)
    }

    static func busyClip() async throws -> URL { try await shared.value }

    /// Upright display size of the first video track.
    static func size(of url: URL) async throws -> CGSize {
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else { return .zero }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let size = natural.applying(transform)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }

    // MARK: Video

    static func makeBusyClip(in directory: URL, seconds: Int = 10, width: Int = 1920, height: Int = 1080) async throws -> URL {
        let silent = directory.appendingPathComponent("busy-silent.mp4")
        let writer = try AVAssetWriter(outputURL: silent, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 30_000_000, AVVideoExpectedSourceFrameRateKey: 30],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let tile = noiseTile(side: 256, amplitude: 255)
        let frames = seconds * 30
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                throw CocoaError(.featureUnsupported)
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let phase = Double(frame) / Double(frames)
            context.setFillColor(CGColor(red: phase, green: 0.4, blue: 1 - phase, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setAlpha(0.5)
            context.draw(tile, in: CGRect(x: (frame * 13) % 256, y: (frame * 7) % 256, width: 256, height: 256), byTiling: true)
            context.setAlpha(1)
            for ball in 0..<6 {
                context.setFillColor(CGColor(red: Double(ball) / 6, green: 1 - phase, blue: 0.5, alpha: 1))
                let x = (frame * (9 + ball * 4) + ball * 300) % width, y = (frame * (5 + ball * 3) + ball * 150) % height
                context.fillEllipse(in: CGRect(x: x, y: y, width: 180, height: 180))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }

        // Add a tone, copying the video as it is.
        let composition = AVMutableComposition()
        let video = AVURLAsset(url: silent)
        let audio = AVURLAsset(url: try Media.tone(seconds: Double(seconds), sampleRate: 44_100, in: directory))
        let range = CMTimeRange(start: .zero, duration: try await video.load(.duration))
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: try await video.loadTracks(withMediaType: .video)[0], at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: try await audio.loadTracks(withMediaType: .audio)[0], at: .zero)
        let output = directory.appendingPathComponent("busy.mov")
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.featureUnsupported)
        }
        session.outputURL = output
        session.outputFileType = .mov
        await session.export()
        guard session.status == .completed else { throw session.error ?? CocoaError(.fileWriteUnknown) }
        return output
    }

    // MARK: Images

    /// Random grey pixels (cheap xorshift), the hardest thing to compress.
    static func noiseTile(side: Int, amplitude: Int) -> CGImage {
        var state: UInt32 = 0x9E37_79B9
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            let value = UInt8(truncatingIfNeeded: Int(state % UInt32(amplitude + 1)))
            bytes[index] = value; bytes[index + 1] = value; bytes[index + 2] = value
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// A photo-like picture: a colour gradient with grain on top.
    static func busyImage(width: Int, height: Int, grain: Int = 40) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
            CGColor(red: 0.9, green: 0.6, blue: 0.2, alpha: 1), CGColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setAlpha(0.25)
        context.draw(noiseTile(side: 512, amplitude: grain * 6), in: CGRect(x: 0, y: 0, width: 512, height: 512), byTiling: true)
        return context.makeImage()!
    }

    static func busyJPEG(width: Int, height: Int) throws -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, busyImage(width: width, height: height),
                                   [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    // MARK: PDF

    /// Letter pages: `scans` full-page pictures (stored losslessly, as scanners often do), then
    /// `textPages` pages of selectable text with a small logo.
    static func pdf(scans: Int, textPages: Int) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw CocoaError(.featureUnsupported)
        }
        let scan = busyImage(width: 1275, height: 1650)
        for _ in 0..<scans {
            context.beginPage(mediaBox: &box)
            context.draw(scan, in: box)
            context.endPage()
        }
        let logo = busyImage(width: 120, height: 120)
        let text = String(repeating: "Quarterly report: sales grew steadily across every region this year. ", count: 30)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil),
        ])
        for _ in 0..<textPages {
            context.beginPage(mediaBox: &box)
            context.draw(logo, in: CGRect(x: 40, y: 700, width: 60, height: 60))
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                                 CGPath(rect: CGRect(x: 40, y: 40, width: 532, height: 640), transform: nil), nil)
            CTFrameDraw(frame, context)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }
}
