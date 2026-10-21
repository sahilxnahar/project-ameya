import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AmeyaEngines

@Suite("WebP output")
struct WebPTests {
    /// Alpha of one pixel (origin top-left).
    static func alpha(of image: CGImage, x: Int, y: Int) -> UInt8? {
        var buffer = [UInt8](repeating: 0, count: 4)
        let drawn = buffer.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
            return true
        }
        return drawn ? buffer[3] : nil
    }

    static func webpDelays(_ data: Data) -> [Double] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        return (0..<CGImageSourceGetCount(source)).compactMap { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let webp = properties?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
            return (webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double) ?? (webp?[kCGImagePropertyWebPDelayTime] as? Double)
        }
    }

    @Test func webpIsAlwaysWritable() {
        #expect(FileFormat.systemWritable().contains(.webp))
    }

    @Test("Still WebP round trip keeps colour and transparency", arguments: [nil, 0.9] as [Double?])
    func stillRoundTrip(quality: Double?) throws {
        let png = try Fixtures.encode([Fixtures.halfTransparent()], as: .png)
        let (webp, result) = try ImageConverter.convert(png, request: ConversionRequest(target: .webp, options: ConversionOptions(quality: quality)))

        #expect(FileFormat.sniff(webp.prefix(32)) == .webp)
        #expect(result.notes.isEmpty)
        let image = try #require(Fixtures.decode(webp)?.first)
        #expect(image.width == 64 && image.height == 48)
        #expect(image.hasAlpha)
        #expect(Self.alpha(of: image, x: 5, y: 24) == 0)
        #expect(Self.alpha(of: image, x: 50, y: 24) == 255)
        let got = try #require(Fixtures.pixel(of: image, x: 50, y: 24))
        let want = try #require(Fixtures.pixel(of: Fixtures.halfTransparent(), x: 50, y: 24))
        // Lossless is exact; lossy is close.
        let tolerance = quality == nil ? 0 : 8
        #expect(abs(Int(got.0) - Int(want.0)) <= tolerance && abs(Int(got.1) - Int(want.1)) <= tolerance
                && abs(Int(got.2) - Int(want.2)) <= tolerance, "\(got) vs \(want)")
    }

    @Test func pngSourceIsLosslessUnlessQualityIsSet() throws {
        // VP8L chunk = lossless, VP8 (with a space) = lossy.
        let png = try Fixtures.encode([Fixtures.halfTransparent()], as: .png)
        let (lossless, _) = try ImageConverter.convert(png, request: ConversionRequest(target: .webp))
        #expect(lossless.range(of: Data("VP8L".utf8)) != nil)

        let (lossy, _) = try ImageConverter.convert(png, request: ConversionRequest(target: .webp, options: ConversionOptions(quality: 0.8)))
        #expect(lossy.range(of: Data("VP8 ".utf8)) != nil)

        let jpeg = try Fixtures.encode(Fixtures.frames(1), as: .jpeg)
        let (fromJPEG, _) = try ImageConverter.convert(jpeg, request: ConversionRequest(target: .webp))
        #expect(fromJPEG.range(of: Data("VP8 ".utf8)) != nil)
    }

    @Test func animatedGIFKeepsFramesAndTiming() throws {
        let gif = try Fixtures.encode(Fixtures.frames(3), as: .gif, delay: 0.2)
        let (webp, result) = try ImageConverter.convert(gif, request: ConversionRequest(target: .webp))

        #expect(result.frames == 3)
        #expect(result.notes.isEmpty)
        let images = try #require(Fixtures.decode(webp))
        #expect(images.count == 3)
        #expect(images.allSatisfy { $0.width == 64 && $0.height == 48 })
        let delays = Self.webpDelays(webp)
        #expect(delays.count == 3)
        #expect(delays.allSatisfy { abs($0 - 0.2) < 0.02 }, "\(delays)")

        // Frames really differ: first is blue-ish, last is red-ish.
        let first = try #require(Fixtures.pixel(of: images[0], x: 10, y: 10))
        let last = try #require(Fixtures.pixel(of: images[2], x: 10, y: 10))
        #expect(first.2 > 200 && last.0 > 200, "\(first) \(last)")
    }

    @Test func animatedWebPConvertsBackToGIF() throws {
        let gif = try Fixtures.encode(Fixtures.frames(3), as: .gif, delay: 0.2)
        let (webp, _) = try ImageConverter.convert(gif, request: ConversionRequest(target: .webp))
        let (back, _) = try ImageConverter.convert(webp, request: ConversionRequest(target: .gif))
        #expect(Fixtures.decode(back)?.count == 3)
    }

    @Test func qualityAffectsSize() throws {
        // A noisy image, so quality has something to throw away.
        let context = Fixtures.context(width: 256, height: 256)
        var generator = SystemRandomNumberGenerator()
        for y in stride(from: 0, to: 256, by: 4) {
            for x in stride(from: 0, to: 256, by: 4) {
                context.setFillColor(CGColor(
                    red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                    blue: .random(in: 0...1, using: &generator), alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        let jpeg = try Fixtures.encode([context.makeImage()!], as: .jpeg)
        let (low, _) = try ImageConverter.convert(jpeg, request: ConversionRequest(target: .webp, options: ConversionOptions(quality: 0.2)))
        let (high, _) = try ImageConverter.convert(jpeg, request: ConversionRequest(target: .webp, options: ConversionOptions(quality: 0.95)))
        #expect(low.count < high.count, "\(low.count) vs \(high.count)")
    }

    @Test func refusesImagesBeyondWebPLimits() throws {
        let context = Fixtures.context(width: WebPEncoder.maxDimension + 1, height: 1)
        let frame = DecodedFrame(image: context.makeImage()!, delay: nil, metadata: [:])
        #expect(throws: ConversionError.self) {
            try WebPEncoder.encode([frame], animated: false, loopCount: 0, quality: nil, lossless: false)
        }
        #expect(throws: ConversionError.self) {
            try WebPEncoder.encode([], animated: false, loopCount: 0, quality: nil, lossless: false)
        }
    }

    @Test func rejectsGarbageInput() {
        #expect(throws: ConversionError.unreadable) {
            try ImageConverter.convert(Data("not an image".utf8), request: ConversionRequest(target: .webp))
        }
    }
}
