import AmeyaCore
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
@testable import AmeyaEngines

/// Generated sounds and clips for the audio and video tool tests, and ways to measure results.
enum AVMedia {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-av-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A 16-bit stereo WAV whose samples come from `left` and `right` (time in seconds → −1…1).
    static func wav(
        seconds: Double, sampleRate: Double = 44_100, in directory: URL, name: String = "sound",
        left: @escaping (Double) -> Double, right: ((Double) -> Double)? = nil
    ) throws -> URL {
        let url = directory.appendingPathComponent("\(name)-\(UUID().uuidString).wav")
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channels = [left, right ?? left]
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) { samples[frame] = Float(channels[channel](Double(frame) / sampleRate)) }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ])
            try file.write(from: buffer)
        }
        return url
    }

    static func sine(_ frequency: Double, amplitude: Double) -> (Double) -> Double {
        { amplitude * sin(2 * .pi * frequency * $0) }
    }

    /// A quiet tone with short full-scale clicks twice a second: raising it to −14 LUFS would push
    /// the clicks about 12 dB over full scale, so evening the volume needs the limiter.
    static func peaky(_ time: Double) -> Double {
        let base = 0.05 * sin(2 * .pi * 220 * time) * (0.7 + 0.3 * sin(2 * .pi * 3 * time))
        let click = time.truncatingRemainder(dividingBy: 0.5) < 0.003 ? 0.95 * sin(2 * .pi * 3_000 * time) : 0
        return base + click
    }

    /// Integrated loudness and true peak of a file, with Ameya's own meter.
    static func loudness(of url: URL) async throws -> (lufs: Double, truePeak: Double) {
        let asset = AVURLAsset(url: url)
        let layout = try await AudioPipeline.layout(of: asset, target: .wav)
        let meter = LoudnessMeter(sampleRate: layout.sampleRate, channels: layout.channels)
        try await AudioPipeline.read(asset, layout: layout) { meter.add($0) }
        return (meter.integratedLoudness ?? -.infinity, meter.truePeakDB)
    }

    /// Integrated loudness and true peak from a reference FFmpeg's `ebur128` filter, when one is
    /// installed on this Mac (the bundled helper is built without it).
    static func referenceLoudness(of url: URL) -> (lufs: Double, truePeak: Double)? {
        let candidates = [ProcessInfo.processInfo.environment["AMEYA_REFERENCE_FFMPEG"], "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        guard let path = candidates.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-hide_banner", "-nostats", "-i", url.path, "-filter_complex", "ebur128=peak=true", "-f", "null", "-"]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard let summary = text.range(of: "Summary:") else { return nil }
        let tail = String(text[summary.upperBound...])
        func value(after label: String) -> Double? {
            guard let range = tail.range(of: label) else { return nil }
            let rest = tail[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return Double(rest.prefix { "-0123456789.".contains($0) })
        }
        guard let lufs = value(after: "I:"), let peak = value(after: "Peak:") else { return nil }
        return (lufs, peak)
    }

    static func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    /// RMS of each channel over `from…to` seconds.
    static func rms(of url: URL, from start: Double, to end: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(start * rate)
        let count = AVAudioFrameCount((end - start) * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
        try file.read(into: buffer, frameCount: count)
        return (0..<Int(file.processingFormat.channelCount)).map { channel in
            let samples = buffer.floatChannelData![channel]
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            return (sum / Float(max(buffer.frameLength, 1))).squareRoot()
        }
    }

    /// The main frequency of the first channel, from zero crossings.
    static func frequency(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let count = AVAudioFrameCount(min(file.length, 44_100))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
        try file.read(into: buffer, frameCount: count)
        let samples = buffer.floatChannelData![0]
        var crossings = 0
        for index in 1..<Int(buffer.frameLength) where (samples[index - 1] < 0) != (samples[index] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(buffer.frameLength) / file.processingFormat.sampleRate)
    }

    // MARK: Video

    /// An H.264 clip of plain-coloured frames (10 fps), optionally with a tone.
    static func clip(width: Int, height: Int, frames: Int, in directory: URL, withAudio: Bool = false) async throws -> URL {
        let images = (0..<frames).map { index -> CGImage in
            let context = Fixtures.context(width: width, height: height)
            let shade = CGFloat(index) / CGFloat(max(frames - 1, 1))
            context.setFillColor(CGColor(red: 0.2 + 0.3 * shade, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()!
        }
        let gif = try Fixtures.encode(images, as: .gif, delay: 0.1)
        let silent = directory.appendingPathComponent("clip-\(width)x\(height)-\(UUID().uuidString).mp4")
        _ = try await VideoConverter.gifToVideo(gif, to: .mp4, output: silent, options: ConversionOptions()) { _ in }
        guard withAudio else { return silent }
        let tone = try wav(seconds: Double(frames) / 10 + 0.5, in: directory, left: sine(440, amplitude: 0.3))
        let output = directory.appendingPathComponent("clip-av-\(UUID().uuidString).mp4")
        try await MediaToolbox.mux(video: silent, audio: tone, target: .mp4, output: output)
        return output
    }

    /// The upright picture at `seconds`.
    static func frame(of url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// Mean absolute difference (0…255) between two same-sized pictures inside `rect` (top-left origin).
    static func difference(_ a: CGImage, _ b: CGImage, in rect: CGRect) -> Double {
        func pixels(_ image: CGImage) -> [UInt8] {
            let context = Fixtures.context(width: a.width, height: a.height)
            context.draw(image, in: CGRect(x: 0, y: 0, width: a.width, height: a.height))
            let data = context.data!.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * a.height)
            return Array(UnsafeBufferPointer(start: data, count: context.bytesPerRow * a.height))
        }
        let (first, second) = (pixels(a), pixels(b))
        let row = Fixtures.context(width: a.width, height: a.height).bytesPerRow
        var total = 0.0, count = 0.0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                for channel in 0..<3 {
                    let index = y * row + x * 4 + channel
                    total += abs(Double(first[index]) - Double(second[index]))
                    count += 1
                }
            }
        }
        return total / max(count, 1)
    }

    static func png(width: Int, height: Int) throws -> Data {
        let context = Fixtures.context(width: width, height: height)
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try Fixtures.encode([context.makeImage()!], as: .png)
    }
}

/// Runs a tool the way the worker does.
@MainActor
func runTool(
    _ tool: MediaTool, inputs: [URL], formats: [FileFormat], target: FileFormat, in directory: URL,
    language: String? = nil
) async throws -> (outputs: [URL], result: ConversionResult) {
    let scratch = directory.appendingPathComponent("scratch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    var options = ConversionOptions(language: language)
    options.media = tool
    let request = ConversionRequest(source: formats[0], target: target, options: options, inputs: formats.count > 1 ? formats : nil)
    return try await Engine.run(inputs: inputs, request: request, scratch: scratch) { _ in }
}
