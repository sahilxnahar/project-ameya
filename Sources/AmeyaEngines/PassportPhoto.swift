import AmeyaCore
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Vision

/// Passport and visa photos: finds one face on-device (Vision), levels the eyes, crops and scales
/// so the head and eye line match the country's rules, and puts a plain background behind the person.
/// Writes a digital JPEG (sRGB, no metadata, within the portal's size limit) and, when asked,
/// a 4×6 in print sheet as JPEG and PDF. Runs inside the sandboxed worker; nothing leaves the Mac.
public enum PassportPhoto {
    /// Faces smaller than this share of the largest face's height are ignored (posters, passers-by).
    static let minorFaceShare = 0.4

    public static func run(
        _ options: PassportPhotoOptions,
        input: URL,
        request: ConversionRequest,
        scratch: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> (outputs: [URL], result: ConversionResult) {
        let spec = options.spec
        guard spec.widthMM >= 10, spec.heightMM >= 10, spec.widthMM <= 200, spec.heightMM <= 200 else {
            throw ConversionError.invalidData("the photo size must be between 10 and 200 mm a side")
        }
        let data: Data
        do { data = try Data(contentsOf: input, options: .mappedIfSafe) } catch { throw ConversionError.unreadable }
        let source = try ImageDecoder.decode(data, options: request.options).frames[0].image
        progress(0.1)

        let analysis = try analyse(source)
        var notes = analysis.notes
        progress(0.35)

        let (prepared, backgroundNotes) = try levelled(source, analysis: analysis, options: options)
        notes += backgroundNotes
        progress(0.6)

        let digitalSize = spec.digitalPixelSize
        let digital = try render(prepared, sourceHeight: source.height, face: analysis.face, spec: spec, width: digitalSize.width,
                                 height: digitalSize.height, notes: &notes)
        let dpi = Double(digitalSize.height) / (spec.heightMM / 25.4)
        let digitalData = try encodeJPEG(digital, dpi: dpi, maxBytes: spec.maxBytes, minBytes: spec.minBytes, notes: &notes)
        if spec.needsCheck { notes.append(.passportCheckRules) }
        var unique: [ConversionNote] = []
        for note in notes where !unique.contains(note) { unique.append(note) }
        progress(0.8)

        let photoURL = scratch.appendingPathComponent("output.jpg")
        try digitalData.write(to: photoURL)
        guard options.printSheet else {
            progress(1)
            return ([photoURL], ConversionResult(outputBytes: digitalData.count, frames: 1, notes: unique))
        }

        let printSize = spec.printPixelSize(dpi: PassportSheet.dpi)
        var ignored: [ConversionNote] = []
        let printPhoto = try render(prepared, sourceHeight: source.height, face: analysis.face, spec: spec, width: printSize.width,
                                    height: printSize.height, notes: &ignored)
        let (sheetJPEG, sheetPDF) = try PassportSheet.make(photo: printPhoto, spec: spec)
        let sheetURL = scratch.appendingPathComponent("sheet.jpg")
        let pdfURL = scratch.appendingPathComponent("sheet.pdf")
        try sheetJPEG.write(to: sheetURL)
        try sheetPDF.write(to: pdfURL)
        progress(1)
        let label = spec.id == PassportSpec.customID ? "" : " (\(spec.name))"
        let names = ["Photo\(label).jpg", "Print sheet 4x6 in\(label).jpg", "Print sheet 4x6 in\(label).pdf"]
        let total = digitalData.count + sheetJPEG.count + sheetPDF.count
        return ([photoURL, sheetURL, pdfURL],
                ConversionResult(outputBytes: total, frames: 1, notes: unique, outputNames: names))
    }

    // MARK: Face

    struct Analysis {
        /// Measured after levelling (rotation about the eye midpoint keeps that point fixed).
        var face: PassportGeometry.Face
        /// Angle of the eye line, radians, top-left coordinates (positive: right eye lower).
        var roll: Double
        var notes: [ConversionNote]
    }

    static func analyse(_ image: CGImage) throws -> Analysis {
        let request = VNDetectFaceLandmarksRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            throw ConversionError.mediaFailed("face detection didn't run (\(error.localizedDescription))")
        }
        let all = request.results ?? []
        let largest = all.map(\.boundingBox.height).max() ?? 0
        let faces = all.filter { $0.boundingBox.height >= largest * minorFaceShare }
        guard let face = faces.first else {
            throw ConversionError.needsDifferentPhoto(
                "No face was found. Use a clear, well-lit photo of one person looking at the camera.")
        }
        guard faces.count == 1 else {
            throw ConversionError.needsDifferentPhoto(
                "This photo shows \(faces.count) faces. Use a photo of just one person.")
        }
        return measure(face, width: image.width, height: image.height)
    }

    /// Eye centres, chin and roll from Vision landmarks (falling back to the face box).
    static func measure(_ face: VNFaceObservation, width: Int, height: Int) -> Analysis {
        let size = CGSize(width: width, height: height)
        let h = Double(height)
        // Vision uses a bottom-left origin; flip to top-left.
        func points(_ region: VNFaceLandmarkRegion2D?) -> [(x: Double, y: Double)] {
            (region?.pointsInImage(imageSize: size) ?? []).map { (Double($0.x), h - Double($0.y)) }
        }
        func centre(_ list: [(x: Double, y: Double)]) -> (x: Double, y: Double)? {
            guard !list.isEmpty else { return nil }
            return (list.map(\.x).reduce(0, +) / Double(list.count), list.map(\.y).reduce(0, +) / Double(list.count))
        }
        let box = VNImageRectForNormalizedRect(face.boundingBox, width, height)
        let boxTop = h - Double(box.maxY), boxBottom = h - Double(box.minY)
        let landmarks = face.landmarks
        let leftEye = points(landmarks?.leftEye), rightEye = points(landmarks?.rightEye)
        let eyeA = centre(points(landmarks?.leftPupil)) ?? centre(leftEye)
        let eyeB = centre(points(landmarks?.rightPupil)) ?? centre(rightEye)

        var notes: [ConversionNote] = []
        let first: (x: Double, y: Double), second: (x: Double, y: Double)
        if let eyeA, let eyeB {
            (first, second) = eyeA.x <= eyeB.x ? (eyeA, eyeB) : (eyeB, eyeA)
        } else { // No landmarks: eyes sit roughly 40 % down the face box.
            let y = boxTop + Double(box.height) * 0.4
            (first, second) = ((Double(box.minX) + Double(box.width) * 0.3, y), (Double(box.minX) + Double(box.width) * 0.7, y))
        }
        let roll = atan2(second.y - first.y, second.x - first.x)
        let mid = ((first.x + second.x) / 2, (first.y + second.y) / 2)
        // Chin: the face contour point furthest down along the face's own vertical axis.
        let down = (-sin(roll), cos(roll))
        let contour = points(landmarks?.faceContour)
        let chinDepth = contour.map { ($0.x - mid.0) * down.0 + ($0.y - mid.1) * down.1 }.max()
            ?? (boxBottom - mid.1)
        let eyeToChin = max(chinDepth, Double(box.height) * 0.25)

        if abs(roll) > 5 * .pi / 180 { notes.append(.passportHeadStraightened) }
        if let yaw = face.yaw?.doubleValue, abs(yaw) > 0.3 { notes.append(.passportFaceTurned) }
        if !leftEye.isEmpty, !rightEye.isEmpty,
           openness(leftEye, roll: roll) < 0.12, openness(rightEye, roll: roll) < 0.12 {
            notes.append(.passportEyesMayBeClosed)
        }
        return Analysis(face: PassportGeometry.Face(eyeX: mid.0, eyeY: mid.1, eyeToChin: eyeToChin), roll: roll, notes: notes)
    }

    /// Height over width of an eye outline, measured along the eye line.
    static func openness(_ eye: [(x: Double, y: Double)], roll: Double) -> Double {
        let along = eye.map { $0.x * cos(roll) + $0.y * sin(roll) }
        let across = eye.map { -$0.x * sin(roll) + $0.y * cos(roll) }
        let width = (along.max() ?? 0) - (along.min() ?? 0)
        guard width > 0 else { return 1 }
        return ((across.max() ?? 0) - (across.min() ?? 0)) / width
    }

    // MARK: Background and levelling

    /// The source with a plain background (when asked) and the eyes level, in Core Image space.
    static func levelled(_ image: CGImage, analysis: Analysis, options: PassportPhotoOptions) throws
        -> (CIImage, [ConversionNote]) {
        var picture = CIImage(cgImage: image)
        var notes: [ConversionNote] = []
        if options.replaceBackground {
            if let mask = try personMask(image) {
                let blend = CIFilter.blendWithMask()
                blend.inputImage = picture
                blend.backgroundImage = backgroundColour(options.spec).cropped(to: picture.extent)
                blend.maskImage = mask
                if let output = blend.outputImage { picture = output.cropped(to: picture.extent) }
                notes.append(.passportBackgroundReplaced)
            } else {
                notes.append(.passportBackgroundKept)
            }
        }
        // Core Image's y axis points up, so the eye line's angle there is -roll; turn it back by +roll.
        let eye = CGPoint(x: analysis.face.eyeX, y: Double(image.height) - analysis.face.eyeY)
        let level = CGAffineTransform(translationX: -eye.x, y: -eye.y)
            .concatenating(CGAffineTransform(rotationAngle: analysis.roll))
            .concatenating(CGAffineTransform(translationX: eye.x, y: eye.y))
        return (abs(analysis.roll) > 0.5 * .pi / 180 ? picture.transformed(by: level) : picture, notes)
    }

    /// A soft-edged person mask the size of `image`, or nil when no person was found.
    static func personMask(_ image: CGImage) throws -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        let raw = CIImage(cvPixelBuffer: buffer)
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let scaled = raw.transformed(by: CGAffineTransform(scaleX: extent.width / raw.extent.width,
                                                           y: extent.height / raw.extent.height))
        let soft = scaled.clampedToExtent()
            .applyingGaussianBlur(sigma: max(1, Double(max(image.width, image.height)) / 900))
            .cropped(to: extent)
        // An empty mask means Vision saw no person: keep the photo as it is.
        let average = CIFilter.areaAverage()
        average.inputImage = scaled
        average.extent = extent
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let mean = average.outputImage else { return nil }
        context.render(mean, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        return pixel[0] < 3 ? nil : soft
    }

    static func backgroundColour(_ spec: PassportSpec) -> CIImage {
        let rgb = spec.background.rgb
        return CIImage(color: CIColor(red: rgb.red, green: rgb.green, blue: rgb.blue,
                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
    }

    // MARK: Render and encode

    static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             .cacheIntermediates: false])

    /// Crops and scales the levelled picture to `width × height` pixels following the spec.
    /// `sourceHeight` is the original image height: levelling rotates in place, so top-left
    /// coordinates still flip against it.
    static func render(_ picture: CIImage, sourceHeight: Int, face: PassportGeometry.Face, spec: PassportSpec,
                       width: Int, height: Int, notes: inout [ConversionNote]) throws -> CGImage {
        let placement = PassportGeometry.placement(for: face, spec: spec, outputWidth: width, outputHeight: height)
        let rect = placement.sourceRect, scale = placement.scale
        let sourceHeight = Double(sourceHeight)
        let move = CGAffineTransform(translationX: -rect.x, y: -(sourceHeight - rect.y - rect.height))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let placed = picture.transformed(by: move, highQualityDownsample: true)
        let output = CGRect(x: 0, y: 0, width: width, height: height)
        let covered = placed.extent.insetBy(dx: -2, dy: -2).contains(output)
        if !covered { notes.append(.passportEdgesFilled) }
        if scale > 1.3 { notes.append(.passportLowResolution) }
        let final = placed.composited(over: backgroundColour(spec)).cropped(to: output)
        guard let image = context.createCGImage(final, from: output, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw ConversionError.encodeFailed(.jpeg)
        }
        return try ImageConverter.flattenOnWhite(image)
    }

    /// JPEG with only the print resolution as metadata, within the portal's byte limits.
    static func encodeJPEG(_ image: CGImage, dpi: Double, maxBytes: Int?, minBytes: Int?,
                           notes: inout [ConversionNote]) throws -> Data {
        let frames = [DecodedFrame(image: image, delay: nil,
                                   metadata: [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi])]
        func jpeg(_ frames: [DecodedFrame], _ quality: Double?) throws -> Data {
            try ImageConverter.encode(frames, as: .jpeg, animated: false, loopCount: 0, quality: quality ?? 0.92) { _ in }
        }
        var data: Data
        if let maxBytes {
            let sizeNotes: [ConversionNote]
            (data, sizeNotes) = try ImageEditor.encode(frames, within: maxBytes, lossy: true, encode: jpeg)
            notes += sizeNotes
        } else {
            data = try jpeg(frames, 0.92)
        }
        if let minBytes, data.count < minBytes {
            let best = try jpeg(frames, 1.0)
            if best.count > data.count && best.count <= (maxBytes ?? .max) { data = best }
        }
        return data
    }
}
