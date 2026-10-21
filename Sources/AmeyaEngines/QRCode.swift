import AmeyaCore
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

/// Makes QR codes from text (Core Image) and reads QR codes and barcodes from images (Vision).
/// Both run on-device; nothing touches the network.
enum QRCode {
    /// Byte-mode capacity of the largest QR code (version 40) at high error correction.
    static let maxBytes = 1273
    /// Smallest side of the generated image, in pixels.
    static let minimumSide = 512
    /// Blank modules around the code, as the QR specification requires.
    static let quietZone = 4

    enum Failure: LocalizedError {
        case tooLong(Int)
        case empty
        case noCodes

        var errorDescription: String? {
            switch self {
            case .tooLong(let bytes):
                "The text is too long for a QR code (\(bytes) bytes; the limit is \(QRCode.maxBytes) with high error correction)."
            case .empty: "The text file is empty, so there is nothing to put in a QR code."
            case .noCodes: "No QR codes or barcodes were found in this image."
            }
        }
    }

    // MARK: Text → QR code

    /// A PNG of `text` as a QR code: high error correction, a 4-module quiet zone, square
    /// modules scaled by a whole number of pixels so edges stay crisp.
    static func png(for text: String) throws -> Data {
        let modules = try matrix(for: text)
        let count = modules.count
        let side = count + 2 * quietZone
        let scale = max(1, Int((Double(minimumSide) / Double(side)).rounded(.up)))
        let pixels = side * scale

        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { throw ConversionError.encodeFailed(.png) }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.setFillColor(gray: 0, alpha: 1)
        for (row, line) in modules.enumerated() {
            for (column, dark) in line.enumerated() where dark {
                // Core Graphics' origin is bottom-left; row 0 is the top of the code.
                let y = pixels - (row + quietZone + 1) * scale
                context.fill(CGRect(x: (column + quietZone) * scale, y: y, width: scale, height: scale))
            }
        }
        guard let image = context.makeImage() else { throw ConversionError.encodeFailed(.png) }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, FileFormat.png.typeIdentifier as CFString, 1, nil) else {
            throw ConversionError.encodeFailed(.png)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodeFailed(.png) }
        return data as Data
    }

    /// The code as rows of dark (true) and light modules, without a quiet zone.
    static func matrix(for text: String) throws -> [[Bool]] {
        let payload = Data(text.utf8)
        guard !payload.isEmpty else { throw Failure.empty }
        guard payload.count <= maxBytes else { throw Failure.tooLong(payload.count) }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw ConversionError.mediaFailed("QR code generation is unavailable")
        }
        filter.setValue(payload, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { throw Failure.tooLong(payload.count) }

        // Render one pixel per module and read it back.
        let width = Int(output.extent.width), height = Int(output.extent.height)
        var gray = [UInt8](repeating: 255, count: width * height)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        gray.withUnsafeMutableBytes { buffer in
            context.render(output, toBitmap: buffer.baseAddress!, rowBytes: width, bounds: output.extent,
                           format: .L8, colorSpace: nil)
        }
        let grid = (0..<height).map { row in (0..<width).map { gray[row * width + $0] < 128 } }

        // Core Image adds its own margin; trim to the dark modules' bounding box.
        let rows = grid.indices.filter { grid[$0].contains(true) }
        let columns = (0..<width).filter { column in grid.contains { $0[column] } }
        guard let top = rows.first, let bottom = rows.last, let left = columns.first, let right = columns.last else {
            throw ConversionError.encodeFailed(.png)
        }
        return grid[top...bottom].map { Array($0[left...right]) }
    }

    // MARK: Image → text

    /// Payloads of every QR code and barcode in the image, top to bottom, left to right.
    static func decode(_ data: Data, options: ConversionOptions) throws -> [String] {
        let decoded = SVGRenderer.looksLikeSVG(data)
            ? try SVGRenderer.decode(data, options: options).0
            : try ImageDecoder.decode(data, options: options)
        guard let image = decoded.frames.first?.image else { throw ConversionError.unreadable }
        return try decode(image)
    }

    static func decode(_ image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            throw ConversionError.mediaFailed("barcode reading failed (\(error.localizedDescription))")
        }
        let found = (request.results ?? [])
            .filter { $0.payloadStringValue?.isEmpty == false }
            // Vision's origin is bottom-left: higher y is nearer the top.
            .sorted { a, b in
                abs(a.boundingBox.midY - b.boundingBox.midY) > 0.02
                    ? a.boundingBox.midY > b.boundingBox.midY
                    : a.boundingBox.midX < b.boundingBox.midX
            }
        var seen = Set<String>()
        let payloads = found.compactMap(\.payloadStringValue).filter { seen.insert($0).inserted }
        guard !payloads.isEmpty else { throw Failure.noCodes }
        return payloads
    }
}
