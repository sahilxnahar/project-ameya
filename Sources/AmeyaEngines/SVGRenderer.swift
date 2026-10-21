import AmeyaCore
import AppKit
import Compression
import CoreGraphics
import Foundation

/// Renders SVG and SVGZ with the system's own SVG support (`NSImage`, backed by CoreSVG).
///
/// Why this route: it ships with macOS, needs no UI, network or WebKit process, and runs
/// inside the sandboxed worker (proved by the bundle self-test). Drawing it into a PDF
/// context keeps shapes and text as vectors. WebKit was not used because a WKWebView needs a
/// window server connection and helper processes that the sandboxed CLI worker should not have.
enum SVGRenderer {
    /// Largest SVG accepted, before and after gzip decompression.
    static let maxInputBytes = 20 << 20
    /// Largest side of a rendered image, in pixels.
    static let maxSide = 16_384
    /// Long side used when the SVG doesn't say how big it is (no absolute width and height).
    static let defaultLongSide = 1024

    struct Document {
        var image: NSImage
        /// The drawing's natural size in points (1 SVG user unit = 1 point = 1 output pixel).
        var size: CGSize
        /// True when the root element has absolute `width` and `height`.
        var hasIntrinsicSize: Bool
        var notes: [ConversionNote]
    }

    /// True when the data is an SVG document or gzip-compressed data (SVGZ when the source says so).
    static func looksLikeSVG(_ data: Data) -> Bool {
        FileFormat.sniff(data.prefix(FileFormat.headerLength)) == .svg
    }

    // MARK: Rendering

    /// Renders the SVG to one transparent bitmap frame.
    static func decode(_ data: Data, options: ConversionOptions) throws -> (DecodedImage, [ConversionNote]) {
        let document = try load(data)
        let (width, height) = try pixelSize(for: document, options: options)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ConversionError.tooLarge(pixels: width * height, limit: options.maxPixels)
        }
        context.interpolationQuality = .high
        draw(document, in: context, rect: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw ConversionError.unreadable }
        let frame = DecodedFrame(image: image, delay: nil, metadata: [:])
        return (DecodedImage(frames: [frame], kind: .single, loopCount: 0), document.notes)
    }

    /// Draws the SVG onto a single PDF page the size of the drawing. Shapes and text stay vectors.
    static func pdf(_ data: Data, options: ConversionOptions) throws -> (Data, [ConversionNote]) {
        let document = try load(data)
        var size = document.size
        if let longSide = options.rasterLongSide, longSide > 0 {
            let scale = CGFloat(longSide) / max(size.width, size.height)
            size = CGSize(width: size.width * scale, height: size.height * scale)
        }
        let output = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ConversionError.encodeFailed(.pdf)
        }
        context.beginPage(mediaBox: &mediaBox)
        draw(document, in: context, rect: mediaBox)
        context.endPage()
        context.closePDF()
        return (output as Data, document.notes)
    }

    private static func draw(_ document: Document, in context: CGContext, rect: CGRect) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        document.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current?.flushGraphics()
        NSGraphicsContext.current = previous
    }

    /// Output pixel size: the SVG's own size, or `rasterLongSide`/1024 px on the long side,
    /// scaled down when needed to stay within 16k px per side and the pixel limit.
    static func pixelSize(for document: Document, options: ConversionOptions) throws -> (Int, Int) {
        let natural = document.size
        var scale: Double = 1
        if let longSide = options.rasterLongSide, longSide > 0 {
            scale = Double(min(longSide, maxSide)) / Double(max(natural.width, natural.height))
        } else if !document.hasIntrinsicSize {
            scale = Double(defaultLongSide) / Double(max(natural.width, natural.height))
        }
        var width = Double(natural.width) * scale
        var height = Double(natural.height) * scale
        let longest = max(width, height)
        if longest > Double(maxSide) {
            width *= Double(maxSide) / longest
            height *= Double(maxSide) / longest
        }
        if width * height > Double(options.maxPixels) {
            let shrink = (Double(options.maxPixels) / (width * height)).squareRoot()
            width *= shrink
            height *= shrink
        }
        return (max(1, Int(width.rounded())), max(1, Int(height.rounded())))
    }

    // MARK: Loading

    static func load(_ data: Data) throws -> Document {
        guard data.count <= maxInputBytes else { throw ConversionError.mediaFailed("The SVG is larger than 20 MB.") }
        var data = data
        if data.starts(with: [0x1F, 0x8B]) {
            data = try gunzip(data, limit: maxInputBytes)
        }
        guard var text = decodeText(data) else { throw ConversionError.unreadable }
        guard case .svg(let rootOffset) = FileFormat.svgRoot(in: Array(text.utf8)) else {
            throw ConversionError.unreadable
        }
        // Entity declarations are how "billion laughs" bombs work; real-world SVGs don't need them.
        if text.range(of: "<!ENTITY", options: .caseInsensitive) != nil { throw ConversionError.unreadable }

        let rootTag = rootStartTag(in: text, utf8Offset: rootOffset)
        var notes: [ConversionNote] = []
        if sanitize(&text) { notes.append(.externalResourcesSkipped) }

        guard let image = NSImage(data: Data(text.utf8)),
              image.representations.contains(where: { String(describing: type(of: $0)).contains("SVG") }) else {
            throw ConversionError.unreadable
        }
        let size = image.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw ConversionError.unreadable
        }
        let intrinsic = isAbsoluteLength(attribute("width", in: rootTag))
            && isAbsoluteLength(attribute("height", in: rootTag))
        return Document(image: image, size: size, hasIntrinsicSize: intrinsic, notes: notes)
    }

    /// UTF-8 (with or without a BOM) or UTF-16 with a BOM, returned as a string whose XML
    /// declaration no longer names a different encoding.
    private static func decodeText(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            guard var text = String(data: data, encoding: .utf16) else { return nil }
            if let range = text.range(of: #"encoding\s*=\s*["'][^"']*["']"#, options: .regularExpression),
               let declarationEnd = text.range(of: "?>"), range.upperBound <= declarationEnd.lowerBound {
                text.replaceSubrange(range, with: #"encoding="UTF-8""#)
            }
            return text
        }
        let body = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(bytes.dropFirst(3)) : data
        return String(data: body, encoding: .utf8)
    }

    /// The text of the root `<svg ...>` start tag.
    private static func rootStartTag(in text: String, utf8Offset: Int) -> String {
        let utf8 = Array(text.utf8)
        guard utf8Offset < utf8.count else { return "" }
        var end = utf8Offset
        var quote: UInt8?
        while end < utf8.count {
            let byte = utf8[end]
            if let open = quote {
                if byte == open { quote = nil }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                quote = byte
            } else if byte == UInt8(ascii: ">") {
                break
            }
            end += 1
        }
        return String(decoding: utf8[utf8Offset..<min(end + 1, utf8.count)], as: UTF8.self)
    }

    /// An attribute's value in a start tag. The name must follow whitespace, so `stroke-width` isn't `width`.
    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"[\s]"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 1...2 {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
        }
        return nil
    }

    /// A length with a number and an optional absolute unit (not a percentage or `auto`).
    static func isAbsoluteLength(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return false }
        return value.range(of: #"^[+]?(\d+\.?\d*|\.\d+)(e[+-]?\d+)?(px|pt|pc|mm|cm|in|em|ex)?$"#, options: .regularExpression) != nil
    }

    /// Removes references to anything outside the document: `href`s and CSS `url()`s that are not
    /// `#fragment` or `data:` URIs, and CSS `@import`. Returns true when something was removed.
    /// The worker's sandbox blocks file and network access anyway; this keeps rendering from
    /// waiting on it and makes the result the same everywhere.
    static func sanitize(_ text: inout String) -> Bool {
        var changed = false
        func isLocal(_ reference: String) -> Bool {
            let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("data:")
        }
        let hrefPattern = #"(?<=[\s])((?:[\w-]+:)?(?:href|src))\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        /// True when an element's start tag has no reference outside the document.
        func elementIsLocal(_ element: String) -> Bool {
            guard let regex = try? NSRegularExpression(pattern: hrefPattern, options: [.caseInsensitive]) else { return false }
            let source = element as NSString
            return regex.matches(in: element, range: NSRange(location: 0, length: source.length)).allSatisfy { match in
                let range = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
                return isLocal(source.substring(with: range))
            }
        }
        func replace(_ pattern: String, group: Int, isKept: (String) -> Bool, with replacement: (String) -> String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            let source = text as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                let reference = source.substring(with: match.range(at: group))
                guard !isKept(reference) else { continue }
                result += source.substring(with: NSRange(location: last, length: match.range.location - last))
                result += replacement(source.substring(with: match.range))
                last = match.range.location + match.range.length
                changed = true
            }
            guard last > 0 else { return }
            result += source.substring(from: last)
            text = result
        }
        // <image> and <feImage> pointing outside are removed whole; with only the link removed,
        // CoreSVG draws a red "missing image" box in their place.
        let element = #"<((?:[\w-]+:)?(?:image|feImage))\b(?:[^>"']|"[^"]*"|'[^']*')*?(?:/>|>[\s\S]*?</\1\s*>)"#
        replace(element, group: 0, isKept: elementIsLocal) { _ in "" }
        // Any other href="…", xlink:href='…', src="…"
        replace(#"(?<=[\s])((?:[\w-]+:)?(?:href|src))\s*=\s*"([^"]*)""#, group: 2, isKept: isLocal) { _ in #"data-ameya-removed="""# }
        replace(#"(?<=[\s])((?:[\w-]+:)?(?:href|src))\s*=\s*'([^']*)'"#, group: 2, isKept: isLocal) { _ in #"data-ameya-removed="""# }
        // url(…) in attributes and style sheets
        replace(#"url\(\s*["']?([^"')]*)["']?\s*\)"#, group: 1, isKept: isLocal) { _ in "none" }
        // @import "…";  @import url(…);  (url() forms were already replaced with none above)
        replace(#"@import\s+(["']?[^;"']*["']?|none)[^;]*;?"#, group: 1, isKept: isLocal) { _ in "" }
        return changed
    }

    // MARK: SVGZ

    /// Decompresses gzip data with the Compression framework, stopping at `limit` bytes.
    static func gunzip(_ data: Data, limit: Int) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
            throw ConversionError.unreadable
        }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard index + 2 <= bytes.count else { throw ConversionError.unreadable }
            index += 2 + (Int(bytes[index]) | Int(bytes[index + 1]) << 8)
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 { // FNAME, FCOMMENT: zero-terminated
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 } // FHCRC
        guard index < bytes.count - 8 else { throw ConversionError.unreadable }

        // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what a gzip member carries.
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ConversionError.unreadable
        }
        defer { compression_stream_destroy(stream) }

        let bufferSize = 64 << 10
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var output = Data()
        let deflate = Array(bytes[index..<(bytes.count - 8)])
        try deflate.withUnsafeBufferPointer { input in
            stream.pointee.src_ptr = input.baseAddress!
            stream.pointee.src_size = input.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = bufferSize
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(buffer, count: bufferSize - stream.pointee.dst_size)
                guard output.count <= limit else { throw ConversionError.mediaFailed("The SVG is larger than 20 MB.") }
                switch status {
                case COMPRESSION_STATUS_END: return
                case COMPRESSION_STATUS_OK:
                    // No progress with input left means the stream is truncated.
                    if stream.pointee.dst_size == bufferSize && stream.pointee.src_size == 0 { throw ConversionError.unreadable }
                default: throw ConversionError.unreadable
                }
            }
        }
        return output
    }
}
