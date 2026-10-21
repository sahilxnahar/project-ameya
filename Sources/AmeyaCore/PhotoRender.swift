import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation

/// Why a photo tool couldn't finish, in plain words.
public enum PhotoToolError: Error, LocalizedError, Equatable {
    case noSubject
    case missingLogo
    case renderFailed

    public var errorDescription: String? {
        switch self {
        case .noSubject: "No clear subject was found to lift out. Try a photo where a person, pet or object stands out from the background."
        case .missingLogo: "The logo picture couldn't be read. Choose a PNG, JPEG or HEIC picture as the logo."
        case .renderFailed: "The picture couldn't be drawn."
        }
    }
}

/// The photo tools' drawing, as pure functions on one upright picture. The worker runs them on
/// the full-size photo; the app runs the very same functions on a small copy for the live preview.
/// Nothing here reads or writes files.
public enum PhotoRender {
    public static let context = CIContext(options: [.cacheIntermediates: false])
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Every photo tool in `edits`, in order: adjust, redact, remove background, annotate,
    /// watermark, add background. `logo` is the decoded logo for a logo watermark.
    public static func apply(_ edits: ImageEdits, to image: CGImage, logo: CGImage? = nil) throws -> CGImage {
        var image = image
        if let adjustments = edits.adjustments, !adjustments.isNeutral { image = try adjusted(image, adjustments) }
        if let redaction = edits.redaction, !redaction.boxes.isEmpty { image = try redacted(image, redaction) }
        if let removal = edits.removeBackground { image = try PhotoVision.removingBackground(image, removal) }
        if let annotations = edits.annotations, !annotations.isEmpty { image = try annotated(image, annotations) }
        if let watermark = edits.watermark { image = try watermarked(image, watermark, logo: logo) }
        if let beautify = edits.beautify { image = try beautified(image, beautify) }
        return image
    }

    // MARK: Adjustments

    public static func adjusted(_ image: CGImage, _ adjustments: PhotoAdjustments) throws -> CGImage {
        let input = CIImage(cgImage: image)
        return try render(adjusted(input, adjustments), extent: input.extent, like: image)
    }

    /// Auto enhance first, then exposure, white balance, contrast and saturation, tone, sharpness, vignette.
    public static func adjusted(_ input: CIImage, _ a: PhotoAdjustments) -> CIImage {
        let extent = input.extent
        let long = Double(max(extent.width, extent.height))
        var picture = input
        if a.autoEnhance == true {
            for filter in picture.autoAdjustmentFilters(options: [.redEye: false]) {
                filter.setValue(picture, forKey: kCIInputImageKey)
                picture = filter.outputImage ?? picture
            }
        }
        if let exposure = a.exposure, exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = picture
            filter.ev = Float(clamp(exposure) * 2)
            picture = filter.outputImage ?? picture
        }
        let warmth = clamp(a.warmth ?? 0), tint = clamp(a.tint ?? 0)
        if warmth != 0 || tint != 0 {
            // Telling Core Image the light was bluer (higher K) than it was warms the picture.
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = picture
            filter.neutral = CIVector(x: 6500 + warmth * 3000, y: tint * 60)
            filter.targetNeutral = CIVector(x: 6500, y: 0)
            picture = filter.outputImage ?? picture
        }
        let contrast = clamp(a.contrast ?? 0), saturation = clamp(a.saturation ?? 0)
        if contrast != 0 || saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = picture
            filter.contrast = Float(1 + contrast * 0.5)
            filter.saturation = Float(1 + saturation)
            filter.brightness = 0
            picture = filter.outputImage ?? picture
        }
        let highlights = clamp(a.highlights ?? 0), shadows = clamp(a.shadows ?? 0)
        if highlights != 0 || shadows != 0 {
            let filter = CIFilter.toneCurve()
            filter.inputImage = picture
            filter.point0 = CGPoint(x: 0, y: 0)
            filter.point1 = CGPoint(x: 0.25, y: 0.25 + 0.12 * shadows)
            filter.point2 = CGPoint(x: 0.5, y: 0.5 + 0.04 * (shadows + highlights))
            filter.point3 = CGPoint(x: 0.75, y: 0.75 + 0.12 * highlights)
            filter.point4 = CGPoint(x: 1, y: 1 + 0.06 * min(highlights, 0))
            picture = filter.outputImage ?? picture
        }
        if let sharpness = a.sharpness, sharpness > 0 {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = picture.clampedToExtent()
            filter.radius = Float(max(1, long / 600))
            filter.intensity = Float(min(sharpness, 1) * 1.5)
            picture = (filter.outputImage ?? picture).cropped(to: extent)
        }
        if let vignette = a.vignette, vignette > 0 {
            let filter = CIFilter.vignetteEffect()
            filter.inputImage = picture
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            filter.radius = Float(hypot(extent.width, extent.height) * 0.3)
            filter.intensity = Float(min(vignette, 1))
            filter.falloff = 0.6
            picture = filter.outputImage ?? picture
        }
        return picture.cropped(to: extent)
    }

    // MARK: Redaction

    /// Covers each box. Blur and pixelate first break the area into large blocks, so the result
    /// can't be sharpened back; black is solid.
    public static func redacted(_ image: CGImage, _ redaction: Redaction) throws -> CGImage {
        let input = CIImage(cgImage: image)
        let long = Double(max(image.width, image.height))
        var result = input
        for box in redaction.boxes {
            let rect = pixelRect(box, width: image.width, height: image.height)
            guard rect.width >= 1, rect.height >= 1 else { continue }
            let short = Double(min(rect.width, rect.height))
            let region = input.cropped(to: rect).clampedToExtent()
            let cover: CIImage
            switch redaction.style {
            case .black:
                cover = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            case .pixelate:
                cover = pixellated(region, at: rect.origin, block: max(8, short / 5, long / 80))
            case .blur:
                cover = pixellated(region, at: rect.origin, block: max(4, short / 10, long / 160))
                    .applyingGaussianBlur(sigma: max(6, short / 4))
            }
            result = cover.cropped(to: rect).composited(over: result)
        }
        return try render(result.cropped(to: input.extent), extent: input.extent, like: image)
    }

    private static func pixellated(_ image: CIImage, at origin: CGPoint, block: Double) -> CIImage {
        let filter = CIFilter.pixellate()
        filter.inputImage = image
        filter.center = origin
        filter.scale = Float(block)
        return filter.outputImage ?? image
    }

    /// A unit box (origin top-left) as whole pixels in Core Image space (origin bottom-left),
    /// rounded outwards so the edge pixels are covered too.
    public static func pixelRect(_ box: UnitRect, width: Int, height: Int) -> CGRect {
        let box = box.clampedToUnit
        let left = floor(box.x * Double(width)), right = ceil((box.x + box.width) * Double(width))
        let top = floor(box.y * Double(height)), bottom = ceil((box.y + box.height) * Double(height))
        return CGRect(x: left, y: Double(height) - bottom, width: right - left, height: bottom - top)
    }

    // MARK: Annotations

    public static func annotated(_ image: CGImage, _ annotations: [Annotation]) throws -> CGImage {
        let width = image.width, height = image.height
        let context = try canvas(width: width, height: height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let long = Double(max(width, height))
        let line = max(2, long * 0.006)
        func point(_ p: PhotoPoint) -> CGPoint { CGPoint(x: p.x * Double(width), y: (1 - p.y) * Double(height)) }

        for mark in annotations {
            let colour = cgColour(mark.colour.rgb)
            let start = point(mark.start), end = point(mark.end)
            context.saveGState()
            context.setStrokeColor(colour)
            context.setFillColor(colour)
            context.setLineWidth(line)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            switch mark.kind {
            case .arrow:
                drawArrow(context, from: start, to: end, line: line, head: max(line * 4, long * 0.025))
            case .rectangle:
                context.stroke(CGRect(from: start, to: end))
            case .highlight:
                context.setBlendMode(.multiply)
                context.setFillColor(cgColour(mark.colour.rgb, alpha: 0.4))
                context.fill(CGRect(from: start, to: end))
            case .text:
                let size = max(12, long * 0.045)
                let text = mark.text ?? ""
                // A thin dark edge keeps light text readable on any background.
                let edge = mark.colour == .black ? cgColour(RGB(1, 1, 1), alpha: 0.8) : cgColour(RGB(0, 0, 0), alpha: 0.55)
                context.setShadow(offset: .zero, blur: size * 0.12, color: edge)
                drawText(text, in: context, size: size, colour: colour, at: CGPoint(x: start.x, y: start.y - size))
            case .step:
                let radius = max(10, long * 0.025)
                context.fillEllipse(in: CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2))
                let label = "\(mark.number ?? 1)"
                let textColour = mark.colour == .white || mark.colour == .yellow ? cgColour(RGB(0, 0, 0)) : cgColour(RGB(1, 1, 1))
                let size = radius * 1.15
                let bounds = textBounds(label, size: size)
                drawText(label, in: context, size: size, colour: textColour,
                         at: CGPoint(x: start.x - bounds.width / 2 - bounds.minX, y: start.y - bounds.height / 2 - bounds.minY))
            }
            context.restoreGState()
        }
        return try made(context, like: image)
    }

    private static func drawArrow(_ context: CGContext, from start: CGPoint, to end: CGPoint, line: Double, head: Double) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = hypot(end.x - start.x, end.y - start.y)
        let head = min(head, max(length * 0.6, line * 2))
        let spread = 0.45
        let base = CGPoint(x: end.x - cos(angle) * head * 0.8, y: end.y - sin(angle) * head * 0.8)
        context.move(to: start)
        context.addLine(to: base)
        context.strokePath()
        context.move(to: end)
        context.addLine(to: CGPoint(x: end.x - cos(angle - spread) * head, y: end.y - sin(angle - spread) * head))
        context.addLine(to: CGPoint(x: end.x - cos(angle + spread) * head, y: end.y - sin(angle + spread) * head))
        context.closePath()
        context.fillPath()
    }

    // MARK: Watermark

    public static func watermarked(_ image: CGImage, _ watermark: Watermark, logo: CGImage?) throws -> CGImage {
        let width = Double(image.width), height = Double(image.height)
        let margin = min(width, height) * 0.03
        let available = (width: width - 2 * margin, height: height - 2 * margin)
        let markWidth = min(max(watermark.size, 0.02), 0.95) * width
        let opacity = min(max(watermark.opacity, 0), 1)
        let context = try canvas(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func place(_ size: CGSize) -> CGPoint {
            let anchor = watermark.position.anchor
            let left = margin + anchor.x * max(0, available.width - size.width)
            let top = margin + anchor.y * max(0, available.height - size.height)
            return CGPoint(x: left, y: height - top - size.height)
        }

        if watermark.useLogo {
            guard let logo, logo.width > 0, logo.height > 0 else { throw PhotoToolError.missingLogo }
            var size = CGSize(width: markWidth, height: markWidth * Double(logo.height) / Double(logo.width))
            if size.height > available.height * 0.9 {
                size = CGSize(width: size.width * available.height * 0.9 / size.height, height: available.height * 0.9)
            }
            context.setAlpha(opacity)
            context.interpolationQuality = .high
            context.draw(logo, in: CGRect(origin: place(size), size: size))
        } else {
            let text = watermark.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return image }
            let reference = textBounds(text, size: 100)
            guard reference.width > 0 else { return image }
            let fontSize = min(100 * markWidth / reference.width, available.height * 0.5 * 100 / max(reference.height, 1))
            let bounds = textBounds(text, size: fontSize)
            let origin = place(bounds.size)
            context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.04), blur: fontSize * 0.12,
                              color: cgColour(RGB(0, 0, 0), alpha: 0.6 * opacity))
            drawText(text, in: context, size: fontSize, colour: cgColour(RGB(1, 1, 1), alpha: opacity),
                     at: CGPoint(x: origin.x - bounds.minX, y: origin.y - bounds.minY))
        }
        return try made(context, like: image)
    }

    // MARK: Background and frame

    /// Pads the picture onto a backdrop with rounded corners, a soft shadow and an optional window frame.
    public static func beautified(_ image: CGImage, _ style: Beautify) throws -> CGImage {
        let width = Double(image.width), height = Double(image.height)
        let long = max(width, height)
        let bar = style.windowFrame ? max(22, (long * 0.045).rounded()) : 0
        let content = CGSize(width: width, height: height + bar)
        let padding = (min(max(style.padding, 0), 0.3) * long).rounded()
        let canvasWidth = Int(content.width + 2 * padding), canvasHeight = Int(content.height + 2 * padding)
        let context = try canvas(width: canvasWidth, height: canvasHeight)
        let whole = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)

        if let colours = style.backdrop.colours {
            let gradient = CGGradient(colorsSpace: sRGB, colors: [cgColour(colours.start), cgColour(colours.end)] as CFArray,
                                      locations: [0, 1])!
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: whole.maxY), end: CGPoint(x: whole.maxX, y: 0), options: [])
        }
        let frame = CGRect(x: padding, y: padding, width: content.width, height: content.height)
        let radius = min(max(style.cornerRadius, 0), 0.1) * min(content.width, content.height)
        let shape = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if style.shadow && padding > 0 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -long * 0.012), blur: long * 0.04,
                              color: cgColour(RGB(0, 0, 0), alpha: 0.38))
            context.addPath(shape)
            context.setFillColor(cgColour(RGB(1, 1, 1)))
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(shape)
        context.clip()
        if bar > 0 {
            let barRect = CGRect(x: frame.minX, y: frame.maxY - bar, width: frame.width, height: bar)
            context.setFillColor(cgColour(RGB(0.93, 0.93, 0.94)))
            context.fill(barRect)
            let dot = bar * 0.22
            let lights = [RGB(1.0, 0.37, 0.34), RGB(1.0, 0.74, 0.18), RGB(0.16, 0.79, 0.25)]
            for (index, light) in lights.enumerated() {
                let centre = CGPoint(x: frame.minX + bar * 0.6 + Double(index) * dot * 3.2, y: barRect.midY)
                context.setFillColor(cgColour(light))
                context.fillEllipse(in: CGRect(x: centre.x - dot, y: centre.y - dot, width: dot * 2, height: dot * 2))
            }
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: frame.minX, y: frame.minY, width: width, height: height))
        context.restoreGState()
        guard let result = context.makeImage() else { throw PhotoToolError.renderFailed }
        return style.backdrop == .transparent ? result : try opaqueCopy(result)
    }

    // MARK: Drawing helpers

    static func textBounds(_ text: String, size: Double) -> CGRect {
        CTLineGetImageBounds(line(text, size: size, colour: cgColour(RGB(0, 0, 0))), nil)
    }

    static func drawText(_ text: String, in context: CGContext, size: Double, colour: CGColor, at origin: CGPoint) {
        context.textMatrix = .identity
        context.textPosition = origin
        CTLineDraw(line(text, size: size, colour: colour), context)
    }

    private static func line(_ text: String, size: Double, colour: CGColor) -> CTLine {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    static func cgColour(_ rgb: RGB, alpha: Double = 1) -> CGColor {
        CGColor(colorSpace: sRGB, components: [rgb.red, rgb.green, rgb.blue, alpha])!
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, -1), 1) }

    /// An sRGB canvas with alpha.
    static func canvas(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PhotoToolError.renderFailed }
        return context
    }

    /// The canvas as an image, opaque again when the source was.
    private static func made(_ context: CGContext, like image: CGImage) throws -> CGImage {
        guard let result = context.makeImage() else { throw PhotoToolError.renderFailed }
        return isOpaque(image) ? try opaqueCopy(result) : result
    }

    /// Renders Core Image output; keeps the source's colour space and, when it had none, its opacity.
    static func render(_ picture: CIImage, extent: CGRect, like image: CGImage) throws -> CGImage {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        guard let result = context.createCGImage(picture, from: extent, format: .RGBA8, colorSpace: space) else {
            throw PhotoToolError.renderFailed
        }
        return isOpaque(image) ? try opaqueCopy(result) : result
    }

    static func isOpaque(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: true
        default: false
        }
    }

    static func opaqueCopy(_ image: CGImage) throws -> CGImage {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw PhotoToolError.renderFailed }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw PhotoToolError.renderFailed }
        return result
    }
}

extension CGRect {
    /// The rectangle spanned by two corners, in any order.
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
