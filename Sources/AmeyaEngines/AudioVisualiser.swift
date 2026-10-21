import Accelerate
import AmeyaCore
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Sound → a square MP4 with moving bars (a spectrum) or a wave over a plain colour, for sharing a
/// recording on apps that only take video. The levels are worked out first (one set per video
/// frame), then the frames are drawn and encoded with H.264, and the sound is added as AAC.
enum AudioVisualiser {
    typealias Job = MediaToolbox.Job

    static let side = 1080
    static let fps = 30
    static let sampleRate = 44_100.0
    static let bands = 32
    static let wavePoints = 96

    static func make(_ input: URL, style: VisualiserStyle, background: RGBColor, job: Job) async throws -> [ConversionNote] {
        let asset = AVURLAsset(url: input)
        let levels = try await analyse(asset, style: style, progress: job.slice(from: 0, to: 0.25).progress)
        guard !levels.isEmpty else { throw ConversionError.refused("The sound is too short to show.") }
        let picture = job.temporary("picture.mp4")
        try await drawVideo(levels, style: style, background: background, to: picture, progress: job.slice(from: 0.25, to: 0.85).progress)
        let sound = job.temporary("sound.m4a")
        let layout = try await AudioPipeline.layout(of: asset, target: .m4a)
        try await AudioTools.writeSound(asset, layout: layout, chain: ProcessorChain([]), channels: layout.channels, source: input,
                                        isVideo: false, format: .m4a, to: sound, job: job.slice(from: 0.85, to: 0.97))
        try await MediaToolbox.mux(video: picture, audio: sound, target: job.target, output: job.output)
        return []
    }

    // MARK: Levels

    /// One array of 0…1 levels per video frame: band energies for bars, the wave's shape for a wave.
    static func analyse(_ asset: AVAsset, style: VisualiserStyle, progress: @escaping @Sendable (Double) -> Void) async throws -> [[Float]] {
        let hop = Int(sampleRate) / fps
        let size = 2048
        let analyser = Spectrum(size: size, bands: bands, sampleRate: sampleRate)
        var pending: [Float] = []
        var window = [Float](repeating: 0, count: size)
        var frames: [[Float]] = []
        var smoothed = [Float](repeating: 0, count: bands)
        try await AudioPipeline.read(asset, layout: .init(sampleRate: sampleRate, channels: 1), progress: progress) { chunk in
            pending += chunk[0]
            while pending.count >= hop {
                let slice = Array(pending.prefix(hop))
                pending.removeFirst(hop)
                window = Array(window.dropFirst(hop)) + slice
                switch style {
                case .bars:
                    let levels = analyser.levels(window)
                    // Rise at once, fall gently, as a meter does.
                    smoothed = zip(levels, smoothed).map { max($0, $1 * 0.82) }
                    frames.append(smoothed)
                case .wave:
                    frames.append(wave(slice))
                }
            }
        }
        return frames
    }

    /// The frame's samples as `wavePoints` peaks, scaled so speech fills the picture.
    static func wave(_ samples: [Float]) -> [Float] {
        let per = max(1, samples.count / wavePoints)
        return (0..<wavePoints).map { point in
            let start = point * per
            guard start < samples.count else { return 0 }
            let part = samples[start..<min(samples.count, start + per)]
            let peak = part.map(abs).max() ?? 0
            return min(1, (peak * 2.2).squareRoot())
        }
    }

    /// Magnitude spectrum in log-spaced bands, as 0…1 over a 60 dB range.
    final class Spectrum {
        let size: Int
        let log2n: vDSP_Length
        let setup: FFTSetup
        let window: [Float]
        let edges: [Int]

        init(size: Int, bands: Int, sampleRate: Double) {
            self.size = size
            log2n = vDSP_Length(log2(Double(size)))
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
            let low = 60.0, high = 14_000.0
            let bin = sampleRate / Double(size)
            edges = (0...bands).map { index in
                let frequency = low * pow(high / low, Double(index) / Double(bands))
                return min(size / 2 - 1, max(1, Int(frequency / bin)))
            }
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        func levels(_ samples: [Float]) -> [Float] {
            let windowed = vDSP.multiply(samples, window)
            var real = [Float](repeating: 0, count: size / 2)
            var imaginary = [Float](repeating: 0, count: size / 2)
            var magnitudes = [Float](repeating: 0, count: size / 2)
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    windowed.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(size / 2))
                }
            }
            let scale = 4 / Float(size) // full-scale sine ≈ 1
            return (0..<(edges.count - 1)).map { band in
                let range = edges[band]...max(edges[band], edges[band + 1] - 1)
                let peak = (magnitudes[range].max() ?? 0) * scale
                let decibels = 20 * log10(max(peak, 1e-6))
                return min(1, max(0, (decibels + 60) / 60))
            }
        }
    }

    // MARK: Drawing

    static func drawVideo(_ levels: [[Float]], style: VisualiserStyle, background: RGBColor, to output: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_000_000, AVVideoMaxKeyFrameIntervalDurationKey: 2],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side,
        ])
        guard writer.canAdd(input) else { throw ConversionError.unsupportedTarget(.mp4) }
        writer.add(input)
        guard writer.startWriting() else { throw ConversionError.mediaFailed(writer.error?.localizedDescription ?? "couldn't start writing") }
        writer.startSession(atSourceTime: .zero)
        let painter = Painter(style: style, background: background)
        for (index, frame) in levels.enumerated() {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard writer.status == .writing, let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw ConversionError.mediaFailed("couldn't draw the picture") }
            painter.draw(frame, into: buffer)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))) else { break }
            if index % 30 == 0 { progress(Double(index) / Double(levels.count)) }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(levels.count), timescale: CMTimeScale(fps)))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ConversionError.mediaFailed(writer.error?.localizedDescription ?? "the video couldn't be written")
        }
    }

    struct Painter {
        let style: VisualiserStyle
        let background: CGColor
        let foreground: CGColor

        init(style: VisualiserStyle, background: RGBColor) {
            self.style = style
            self.background = CGColor(srgbRed: background.red, green: background.green, blue: background.blue, alpha: 1)
            // Light marks on dark colours, dark marks on light ones.
            let luminance = 0.2126 * background.red + 0.7152 * background.green + 0.0722 * background.blue
            foreground = luminance > 0.6 ? CGColor(gray: 0.1, alpha: 0.9) : CGColor(gray: 1, alpha: 0.92)
        }

        func draw(_ levels: [Float], into buffer: CVPixelBuffer) {
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }
            let size = CGFloat(side)
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.setFillColor(foreground)
            let middle = size / 2
            let usable = size * 0.8
            let margin = (size - usable) / 2
            let slot = usable / CGFloat(max(levels.count, 1))
            let width = max(2, slot * (style == .bars ? 0.62 : 0.5))
            for (index, level) in levels.enumerated() {
                let height = max(width, CGFloat(level) * size * (style == .bars ? 0.6 : 0.7))
                let x = margin + CGFloat(index) * slot + (slot - width) / 2
                let rect = CGRect(x: x, y: middle - height / 2, width: width, height: height)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
            }
            context.fillPath()
        }
    }
}
