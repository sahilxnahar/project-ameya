import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO

/// Exercises the real bundle: sandbox, worker launch, conversion and safe output.
/// Run as `Ameya.app/Contents/MacOS/Ameya --self-test`.
enum SelfTest {
    static func run() async -> Bool {
        guard let worker = Bundle.main.url(forAuxiliaryExecutable: "AmeyaWorker") else {
            print("FAIL worker executable not found in bundle")
            return false
        }
        let runner = WorkerRunner(executable: worker, timeout: .seconds(60))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ameya-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = directory.appendingPathComponent("source.png")
            let original = try makeTransparentPNG()
            try original.write(to: source)

            var allPassed = true
            let writable = FileFormat.systemWritable()
            print("writable formats: \(writable.map(\.rawValue).sorted().joined(separator: ", "))")
            for target in FileFormat.allCases where writable.contains(target) && target != .png {
                let destination = OutputPlanner.destination(for: source, target: target, in: directory)
                do {
                    let result = try await runner.run(input: source, destination: destination, request: ConversionRequest(target: target))
                    let readable = isReadable(destination, as: target)
                    print("\(readable ? "PASS" : "FAIL") png -> \(target.rawValue): \(result.outputBytes) bytes \(result.notes.map(\.rawValue))")
                    allPassed = allPassed && readable
                } catch {
                    print("FAIL png -> \(target.rawValue): \(error.localizedDescription)")
                    allPassed = false
                }
            }

            let unchanged = (try? Data(contentsOf: source)) == original
            print("\(unchanged ? "PASS" : "FAIL") source file unchanged")
            print(allPassed && unchanged ? "SELFTEST OK" : "SELFTEST FAILED")
            return allPassed && unchanged
        } catch {
            print("FAIL setup: \(error.localizedDescription)")
            return false
        }
    }

    /// A 64×48 PNG whose left half is transparent.
    private static func makeTransparentPNG() throws -> Data {
        guard let context = CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.featureUnsupported) }
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 48))
        guard let image = context.makeImage() else { throw CocoaError(.featureUnsupported) }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.featureUnsupported)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    private static func isReadable(_ url: URL, as format: FileFormat) -> Bool {
        if format == .pdf {
            return CGPDFDocument(url as CFURL).map { $0.numberOfPages == 1 } ?? false
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        return image.width == 64 && image.height == 48
    }
}
