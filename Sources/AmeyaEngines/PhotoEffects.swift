import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO

/// The worker's side of the photo tools: runs `PhotoRender` on every frame at full size, and
/// makes redaction irreversible by dropping all metadata (and so any embedded thumbnail).
enum PhotoEffects {
    /// A logo watermark arrives as the job's second input. Reads it, keeps it as PNG inside the
    /// request, and returns the photo as the only input. Other requests pass through unchanged.
    static func attachLogo(inputs: [URL], request: ConversionRequest) throws -> ([URL], ConversionRequest) {
        guard var watermark = request.options.image?.watermark, watermark.useLogo, watermark.logoPNG == nil else {
            return (inputs, request)
        }
        guard inputs.count == 2 else { throw ConversionError.needsDifferentPhoto(PhotoToolError.missingLogo.errorDescription!) }
        let data: Data
        do { data = try Data(contentsOf: inputs[1], options: .mappedIfSafe) } catch { throw ConversionError.unreadable }
        guard var logo = try? ImageDecoder.decode(data, options: request.options).frames.first?.image else {
            throw ConversionError.needsDifferentPhoto(PhotoToolError.missingLogo.errorDescription!)
        }
        if max(logo.width, logo.height) > 2048 { logo = try ImageEditor.scaled(logo, by: 2048 / Double(max(logo.width, logo.height))) }
        watermark.logoPNG = try ImageConverter.encode([DecodedFrame(image: logo, delay: nil, metadata: [:])], as: .png,
                                                      animated: false, loopCount: 0, quality: nil) { _ in }
        var request = request
        request.options.image?.watermark = watermark
        request.inputs = nil
        return ([inputs[0]], request)
    }

    static func hasPhotoTools(_ edits: ImageEdits) -> Bool {
        edits.adjustments != nil || edits.redaction != nil || edits.removeBackground != nil
            || edits.annotations != nil || edits.watermark != nil || edits.beautify != nil
    }

    /// Applies the photo tools to every frame (only the first for background removal). Returns notes.
    static func apply(_ edits: ImageEdits, to frames: inout [DecodedFrame]) throws -> [ConversionNote] {
        guard hasPhotoTools(edits), !frames.isEmpty else { return [] }
        var notes: [ConversionNote] = []
        var logo: CGImage?
        if let png = edits.watermark?.logoPNG {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ConversionError.unreadable }
            logo = image
        }
        if edits.removeBackground != nil, frames.count > 1 {
            frames = [frames[0]]
            notes.append(.onlyFirstFrameKept)
        }
        do {
            frames = try frames.map { frame in
                var frame = frame
                let before = (frame.image.width, frame.image.height)
                frame.image = try PhotoRender.apply(edits, to: frame.image, logo: logo)
                if before != (frame.image.width, frame.image.height) {
                    frame.metadata = ImageEditor.applyPolicy(.removeAll, to: frame.metadata)
                }
                return frame
            }
        } catch let error as PhotoToolError {
            throw ConversionError.needsDifferentPhoto(error.errorDescription ?? "The photo couldn't be changed.")
        }
        if let redaction = edits.redaction, !redaction.boxes.isEmpty {
            // Nothing that could show the original survives: no EXIF (with its thumbnail), GPS, IPTC or TIFF.
            for index in frames.indices { frames[index].metadata = [:] }
            notes.append(.redactionBurnedIn)
        }
        if edits.removeBackground != nil { notes.append(.backgroundRemoved) }
        return notes
    }
}
