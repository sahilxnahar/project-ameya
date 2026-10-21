import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class BundleMarker {}

enum Fixtures {
    /// The build products folder (where `swift build` put Ameya and AmeyaWorker).
    static var products: URL { Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent() }
    static var worker: URL { products.appendingPathComponent("AmeyaWorker") }
    static var app: URL { products.appendingPathComponent("Ameya") }
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-apptests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A small opaque picture, written as `type` (PNG or JPEG).
    static func picture(at url: URL, width: Int = 64, height: Int = 48, type: UTType = .png) throws {
        let context = try requireContext(width: width, height: height)
        context.setFillColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func requireContext(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return context
    }

    static func pixelSize(of url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// Runs a program and collects its output.
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:],
                    in directory: URL? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { $1 }
        process.environment = env
        if let directory { process.currentDirectoryURL = directory }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }
}
