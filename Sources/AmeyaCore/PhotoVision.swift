import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Vision

/// On-device Vision for the photo tools: finding faces, text and number plates to redact, and
/// lifting the subject off its background. Nothing leaves the Mac.
public enum PhotoVision {
    // MARK: Finders (boxes in unit coordinates, origin top-left)

    /// Faces, grown a little to cover hair and ears.
    public static func faces(in image: CGImage) -> [UnitRect] {
        let request = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return [] }
        return (request.results ?? []).map { unit($0.boundingBox).padded(by: 0.2) }
    }

    /// Lines of text.
    public static func text(in image: CGImage) -> [UnitRect] {
        textLines(in: image).map { $0.box.padded(by: 0.08) }
    }

    /// Text that looks like a number plate: short, capitals and digits, wide and low.
    public static func numberPlates(in image: CGImage) -> [UnitRect] {
        textLines(in: image).filter { line in
            isPlateLike(line.text, width: line.box.width * Double(image.width), height: line.box.height * Double(image.height))
        }.map { $0.box.padded(by: 0.25) }
    }

    /// 4–10 letters and digits (spaces, dashes and dots aside), at least one digit, no lower case,
    /// and a box between 1.8 and 7 times as wide as it is tall.
    public static func isPlateLike(_ text: String, width: Double, height: Double) -> Bool {
        let characters = text.filter { !$0.isWhitespace && !"-·.".contains($0) }
        guard (4...10).contains(characters.count), height > 0,
              characters.allSatisfy({ $0.isASCII && ($0.isNumber || ($0.isLetter && $0.isUppercase)) }),
              characters.contains(where: \.isNumber) else { return false }
        return (1.8...7).contains(width / height)
    }

    static func textLines(in image: CGImage) -> [(box: UnitRect, text: String)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            return (unit(observation.boundingBox), best.string)
        }
    }

    /// Vision's normalised rectangle (origin bottom-left) as a unit rectangle (origin top-left).
    static func unit(_ box: CGRect) -> UnitRect {
        UnitRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height).clampedToUnit
    }

    // MARK: Subject lift

    /// The subject mask at the picture's size, or `nil` when Vision sees no subject.
    public static func subjectMask(_ image: CGImage, subjects: BackgroundRemoval.Subjects) throws -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
        var instances = observation.allInstances
        if subjects == .largest, instances.count > 1,
           let largest = instances.max(by: { area(of: $0, in: observation.instanceMask) < area(of: $1, in: observation.instanceMask) }) {
            instances = IndexSet(integer: largest)
        }
        let buffer = try observation.generateScaledMaskForImage(forInstances: instances, from: handler)
        let mask = CIImage(cvPixelBuffer: buffer)
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard mask.extent.width > 0, mask.extent.height > 0 else { return nil }
        return mask.transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width,
                                                      y: extent.height / mask.extent.height)).cropped(to: extent)
    }

    /// Pixels labelled `instance` in Vision's low-resolution label map.
    static func area(of instance: Int, in labels: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(labels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(labels) else { return 0 }
        let width = CVPixelBufferGetWidth(labels), height = CVPixelBufferGetHeight(labels)
        let stride = CVPixelBufferGetBytesPerRow(labels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var count = 0
        for row in 0..<height {
            for column in 0..<width where Int(bytes[row * stride + column]) == instance { count += 1 }
        }
        return count
    }

    /// The subject on transparency; as a sticker, with a white outline and a soft shadow on a
    /// slightly larger canvas.
    public static func removingBackground(_ image: CGImage, _ removal: BackgroundRemoval) throws -> CGImage {
        guard let mask = try subjectMask(image, subjects: removal.subjects) else { throw PhotoToolError.noSubject }
        let picture = CIImage(cgImage: image)
        let extent = picture.extent
        let cut = picture.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
        ])
        guard removal.sticker else { return try renderWithAlpha(cut, extent: extent) }

        let long = Double(max(extent.width, extent.height))
        let outline = max(3, long * 0.014)
        let margin = (outline * 4).rounded()
        let canvas = extent.insetBy(dx: -margin, dy: -margin)
        let grown = mask.clampedToExtent().cropped(to: canvas)
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: min(outline, 100)])
            .applyingGaussianBlur(sigma: 1).cropped(to: canvas)
        func filled(_ colour: CIColor) -> CIImage {
            CIImage(color: colour).cropped(to: canvas).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: grown,
            ])
        }
        let white = filled(CIColor(red: 1, green: 1, blue: 1))
        let shadow = filled(CIColor(red: 0, green: 0, blue: 0, alpha: 0.35))
            .applyingGaussianBlur(sigma: outline * 1.2)
            .transformed(by: CGAffineTransform(translationX: 0, y: -outline * 0.8))
        let sticker = cut.composited(over: white).composited(over: shadow).cropped(to: canvas)
        return try renderWithAlpha(sticker.transformed(by: CGAffineTransform(translationX: margin, y: margin)),
                                   extent: CGRect(origin: .zero, size: canvas.size))
    }

    private static func renderWithAlpha(_ picture: CIImage, extent: CGRect) throws -> CGImage {
        guard let result = PhotoRender.context.createCGImage(picture, from: extent, format: .RGBA8,
                                                             colorSpace: PhotoRender.sRGB) else {
            throw PhotoToolError.renderFailed
        }
        return result
    }
}
