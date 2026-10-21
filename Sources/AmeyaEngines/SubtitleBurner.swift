import AmeyaCore
@preconcurrency import AVFoundation
import CoreImage
import CoreText
import Foundation

/// Draws captions into a video's picture. Each frame passes through an AVVideoComposition whose
/// Core Image handler lays the caption for that moment over it: white bold text with a dark
/// outline on a translucent box, sized to the picture's height, centred near the bottom.
enum SubtitleBurner {
    typealias Job = MediaToolbox.Job
    typealias Cue = SubtitleConverter.Cue

    /// The cues of any subtitle format Ameya reads, as plain text.
    static func cues(from url: URL, format: FileFormat) throws -> [Cue] {
        let data = try Data(contentsOf: url)
        let srt: String
        if format == .srt || format == .vtt {
            srt = DocumentConverter.decodeText(data)
        } else {
            srt = String(decoding: try SubtitleConverter.convert(data, from: format, to: .srt).0, as: UTF8.self)
        }
        let cues = SubtitleConverter.parse(srt.replacingOccurrences(of: "\u{FEFF}", with: "")).0
            .map { Cue(start: $0.start, end: $0.end, text: SubtitleConverter.plainText($0.text)) }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !cues.isEmpty else { throw ConversionError.noSubtitles }
        return cues.sorted { $0.start < $1.start }
    }

    /// Recognises the speech (on this Mac) and lays it out as captions.
    static func transcribe(_ input: URL, language: String?, job: Job) async throws -> [Cue] {
        let audio = job.temporary("speech.caf")
        let duration = try await Transcriber.prepareAudio(from: input, to: audio) { job.progress(0.05 * $0) }
        let progress = job.progress
        let words = try await Transcriber.recognise(audio, duration: duration, language: language) { progress(0.05 + 0.55 * $0) }
        guard !words.isEmpty else { throw TranscriptionError.noSpeech }
        return Transcriber.cues(from: words)
    }

    static func burn(_ cues: [Cue], into input: URL, job: Job) async throws -> [ConversionNote] {
        guard let fileType = VideoConverter.fileType(for: job.target) else { throw ConversionError.unsupportedTarget(job.target) }
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ConversionError.noVideoTrack }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let shown = CGRect(origin: .zero, size: natural).applying(transform)
        let renderer = CaptionRenderer(cues: cues, frame: CGSize(width: abs(shown.width), height: abs(shown.height)))
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let source = request.sourceImage
            if let caption = renderer.caption(at: request.compositionTime.seconds) {
                request.finish(with: caption.composited(over: source), context: nil)
            } else {
                request.finish(with: source, context: nil)
            }
        }
        try await MediaToolbox.export(asset, preset: AVAssetExportPresetHighestQuality, fileType: fileType, to: job.output,
                                      videoComposition: composition, progress: job.progress)
        return [.captionsBurnedIn]
    }
}

/// Draws each caption once, when first needed, and keeps the few most recent. Called from Core
/// Image's rendering threads, so the cache is behind a lock.
final class CaptionRenderer: @unchecked Sendable {
    let cues: [SubtitleConverter.Cue]
    let frame: CGSize
    private let lock = NSLock()
    private var cache: [Int: CIImage] = [:]
    private var order: [Int] = []

    init(cues: [SubtitleConverter.Cue], frame: CGSize) {
        self.cues = cues
        self.frame = frame
    }

    /// The caption showing at `seconds`, positioned in the frame, or `nil` between captions.
    func caption(at seconds: Double) -> CIImage? {
        let milliseconds = Int((seconds * 1000).rounded())
        guard let index = cues.lastIndex(where: { $0.start <= milliseconds && milliseconds < $0.end }) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let image = cache[index] { return image }
        guard let image = render(cues[index].text) else { return nil }
        cache[index] = image
        order.append(index)
        if order.count > 8 { cache[order.removeFirst()] = nil }
        return image
    }

    /// Font size: about 5.5 % of the picture's height, as broadcast captions are.
    var fontSize: CGFloat { max(14, frame.height * 0.055) }

    func render(_ text: String) -> CIImage? {
        let size = fontSize
        let baseFont = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let font = CTFontCreateCopyWithSymbolicTraits(baseFont, size, nil, .traitBold, .traitBold) ?? baseFont
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafeBytes(of: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                  value: pointer.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        func attributed(stroke: Bool) -> CFAttributedString {
            var attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTParagraphStyleAttributeName: paragraph]
            if stroke {
                attributes[kCTStrokeWidthAttributeName] = 14.0 // percent of the font size; positive = outline only
                attributes[kCTStrokeColorAttributeName] = CGColor(gray: 0, alpha: 1)
            } else {
                attributes[kCTForegroundColorAttributeName] = CGColor(gray: 1, alpha: 1)
            }
            return CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        }
        let fill = CTFramesetterCreateWithAttributedString(attributed(stroke: false))
        let maxWidth = frame.width * 0.86
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(fill, CFRange(location: 0, length: 0), nil,
                                                                  CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let padding = (size * 0.4).rounded()
        let textSize = CGSize(width: ceil(fitted.width) + 2, height: ceil(fitted.height) + 2)
        let box = CGSize(width: textSize.width + 2 * padding, height: textSize.height + padding)
        guard let context = CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let radius = size * 0.25
        context.setFillColor(CGColor(gray: 0, alpha: 0.55))
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: box), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        let textRect = CGRect(x: padding, y: padding / 2, width: textSize.width, height: textSize.height)
        for framesetter in [CTFramesetterCreateWithAttributedString(attributed(stroke: true)), fill] {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: textRect, transform: nil), nil)
            CTFrameDraw(frame, context)
        }
        guard let image = context.makeImage() else { return nil }
        let x = ((frame.width - box.width) / 2).rounded()
        let y = (frame.height * 0.06).rounded()
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: x, y: y))
    }
}
