import AmeyaCore
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Self-test checks for the size presets and video edits, run through the sandboxed worker
/// exactly as the app runs them: photo under 200 KB, video fit-for-email and a 1 MB target,
/// trim & mute, PDF compression and (with the helper) an MKV trim.
extension SelfTest.Checker {
    mutating func checkPresets() async {
        let catalog = ToolCatalog(writable: FileFormat.systemWritable())
        func tool(_ id: String) -> Tool { catalog.tools.first { $0.id == id }! }

        do {
            let photo = directory.appendingPathComponent("busy photo.jpg")
            try PresetSamples.photo(width: 3000, height: 2000).write(to: photo)
            let small = directory.appendingPathComponent("busy photo (under 200 KB).jpg")
            if await runPreset(tool("image.under200KB"), photo, .jpeg, to: small) != nil {
                let bytes = size(small)
                verify(bytes > 0 && bytes <= 200_000 && FileFormat.detect(at: small) == .jpeg, "photo under 200 KB", "\(bytes) bytes")
            }

            let clip = directory.appendingPathComponent("busy clip.mov")
            try await PresetSamples.clip(to: clip, in: directory)
            let email = directory.appendingPathComponent("busy clip (email).mp4")
            if let result = await runPreset(tool("video.email"), clip, .mov, to: email) {
                let bytes = size(email)
                verify(bytes > 0 && bytes <= 25_000_000 && FileFormat.detect(at: email) == .mp4, "video fit for email",
                       "\(bytes) bytes \(result.notes.map(\.rawValue))")
            }
            let tiny = directory.appendingPathComponent("busy clip (1 MB).mp4")
            let oneMB = ConversionOptions(video: VideoEdits(targetBytes: 1_000_000))
            if let result = await runPreset(tool("video.email"), clip, .mov, to: tiny, options: oneMB) {
                verify(size(tiny) <= 1_000_000, "video under 1 MB", "\(size(tiny)) bytes \(result.notes.map(\.rawValue))")
            }

            let trimmed = directory.appendingPathComponent("busy clip (trimmed).mov")
            let trim = ConversionOptions(video: VideoEdits(trimStart: 1, trimEnd: 2.5, mute: true))
            if await runPreset(tool("video.trim"), clip, .mov, to: trimmed, options: trim) != nil {
                let asset = AVURLAsset(url: trimmed)
                let seconds = (try? await asset.load(.duration).seconds) ?? 0
                let silent = (try? await asset.loadTracks(withMediaType: .audio).isEmpty) ?? false
                verify(abs(seconds - 1.5) <= 0.1 && silent, "trim & mute", "\(seconds) s, silent: \(silent)")
            }

            let scan = directory.appendingPathComponent("scan.pdf")
            let scanData = try PresetSamples.scannedPDF(pages: 2)
            try scanData.write(to: scan)
            let smaller = directory.appendingPathComponent("scan (smaller).pdf")
            if let result = await runPreset(tool("pdf.smaller"), scan, .pdf, to: smaller) {
                let bytes = size(smaller)
                verify(bytes > 0 && bytes < scanData.count / 2 && SelfTest.pageCount(smaller) == 2, "PDF compress",
                       "\(scanData.count) -> \(bytes) bytes \(result.notes.map(\.rawValue))")
            }

            if FFmpegAvailability.isAvailable {
                let mkv = directory.appendingPathComponent("busy clip.mkv")
                _ = try await runner.run(input: clip, destination: mkv,
                                         request: ConversionRequest(source: .mov, target: .mkv))
                let cut = directory.appendingPathComponent("busy clip (trimmed).mkv")
                let options = ConversionOptions(video: VideoEdits(trimStart: 0.5, trimEnd: 2, mute: true))
                if await runPreset(tool("video.trim"), mkv, .mkv, to: cut, options: options) != nil {
                    verify(FileFormat.detect(at: cut) == .mkv && size(cut) > 0, "trim MKV keep MKV", "\(size(cut)) bytes")
                }
            }
        } catch {
            verify(false, "presets setup", "\(error)")
        }
    }

    private mutating func runPreset(
        _ tool: Tool, _ input: URL, _ format: FileFormat, to destination: URL, options: ConversionOptions? = nil
    ) async -> ConversionResult? {
        var request = tool.makeRequest(format)
        if let options { request.options = options }
        do {
            return try await runner.run(input: input, destination: destination, request: request)
        } catch {
            verify(false, tool.title, error.localizedDescription)
            return nil
        }
    }

    private func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private mutating func verify(_ passed: Bool, _ label: String, _ detail: String) {
        print(passed ? "PASS preset \(label): \(detail)" : "FAIL preset \(label): \(detail)")
        if !passed { allPassed = false }
    }
}

/// Busy, hard-to-compress samples, so byte targets actually have work to do.
enum PresetSamples {
    static func noise(side: Int) -> CGImage {
        var state: UInt32 = 0x2545_F491
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            let value = UInt8(truncatingIfNeeded: state)
            bytes[index] = value; bytes[index + 1] = value; bytes[index + 2] = value
        }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func picture(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setAlpha(0.3)
        context.draw(noise(side: 256), in: CGRect(x: 0, y: 0, width: 256, height: 256), byTiling: true)
        return context.makeImage()!
    }

    /// A page-sized picture with fine grain everywhere, like a scan: costly to store losslessly.
    static func scanImage(width: Int, height: Int) -> CGImage {
        var state: UInt32 = 0x1B87_3593
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5
                let grain = Int(state % 25)
                let index = (y * width + x) * 4
                bytes[index] = UInt8(min(255, 180 + grain + x * 40 / width))
                bytes[index + 1] = UInt8(min(255, 170 + grain + y * 40 / height))
                bytes[index + 2] = UInt8(min(255, 160 + grain))
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func photo(width: Int, height: Int) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw CocoaError(.featureUnsupported)
        }
        CGImageDestinationAddImage(destination, picture(width: width, height: height),
                                   [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    /// Full-page pictures stored losslessly, as many scanners do.
    static func scannedPDF(pages: Int) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw CocoaError(.featureUnsupported)
        }
        let scan = scanImage(width: 1275, height: 1650)
        for _ in 0..<pages {
            context.beginPage(mediaBox: &box)
            context.draw(scan, in: box)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A 3 s 1280×720 clip of moving noise at ~20 Mbit/s, with a tone.
    static func clip(to output: URL, in directory: URL) async throws {
        let (width, height, frames) = (1280, 720, 90)
        let silent = directory.appendingPathComponent("busy-silent.mp4")
        let writer = try AVAssetWriter(outputURL: silent, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let tile = noise(side: 256)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                throw CocoaError(.featureUnsupported)
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                context.setFillColor(CGColor(red: Double(frame) / Double(frames), green: 0.4, blue: 0.6, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.setAlpha(0.5)
                context.draw(tile, in: CGRect(x: frame * 11 % 256, y: frame * 5 % 256, width: 256, height: 256), byTiling: true)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }

        let tone = directory.appendingPathComponent("busy-tone.wav")
        try writeTone(seconds: 3, to: tone)

        let composition = AVMutableComposition()
        let video = AVURLAsset(url: silent), audio = AVURLAsset(url: tone)
        let range = CMTimeRange(start: .zero, duration: try await video.load(.duration))
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: try await video.loadTracks(withMediaType: .video)[0], at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: try await audio.loadTracks(withMediaType: .audio)[0], at: .zero)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.featureUnsupported)
        }
        session.outputURL = output
        session.outputFileType = .mov
        await session.export()
        guard session.status == .completed else { throw session.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// A 440 Hz tone. The file closes when this returns, so it can be read straight after.
    private static func writeTone(seconds: Int, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        let samples = AVAudioFrameCount(44_100 * seconds)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: samples)!
        pcm.frameLength = samples
        for channel in 0..<2 {
            for index in 0..<Int(samples) { pcm.floatChannelData![channel][index] = 0.3 * sin(2 * .pi * 440 * Float(index) / 44_100) }
        }
        try file.write(from: pcm)
    }
}
