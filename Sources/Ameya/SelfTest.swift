import AmeyaCore
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Exercises the real bundle: sandbox, worker launch, every engine and safe output.
/// Run as `Ameya.app/Contents/MacOS/Ameya --self-test`.
enum SelfTest {
    static func run() async -> Bool {
        guard let worker = Bundle.main.url(forAuxiliaryExecutable: "AmeyaWorker") else {
            print("FAIL worker executable not found in bundle")
            return false
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ameya-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var check = Checker(runner: WorkerRunner(executable: worker, timeout: .seconds(120)), directory: directory)

            let png = directory.appendingPathComponent("source.png")
            let originalPNG = try makeTransparentPNG()
            try originalPNG.write(to: png)
            let matrix = ConversionMatrix(writable: FileFormat.systemWritable())
            for target in matrix.targets(for: .png) {
                await check.convert(png, from: .png, to: target)
            }

            let text = directory.appendingPathComponent("notes.txt")
            try Data("Ameya self-test\nSecond line with ünïcødé.".utf8).write(to: text)
            if let docx = await check.convert(text, from: .txt, to: .docx) {
                await check.convert(docx, from: .docx, to: .pdf)
                await check.convert(docx, from: .docx, to: .odt)
            }
            await check.convert(text, from: .txt, to: .html)

            let markdown = directory.appendingPathComponent("book.md")
            try Data("# Book\n\nOpening.\n\n## One\n\nFirst chapter.\n\n## Two\n\nSecond chapter.\n".utf8).write(to: markdown)
            if let epub = await check.convert(markdown, from: .md, to: .epub),
               let pdf = await check.convert(epub, from: .epub, to: .pdf),
               let cbz = await check.convert(pdf, from: .pdf, to: .cbz) {
                await check.convert(cbz, from: .cbz, to: .pdf)
            }

            let wav = directory.appendingPathComponent("tone.wav")
            try writeTone(to: wav)
            for target in [FileFormat.m4a, .alac, .flac, .aiff] {
                await check.convert(wav, from: .wav, to: target)
            }

            if let gif = await check.convert(png, from: .png, to: .gif),
               let mp4 = await check.convert(gif, from: .gif, to: .mp4) {
                await check.convert(mp4, from: .mp4, to: .mov)
                await check.convert(mp4, from: .mp4, to: .gif)
            }

            let srt = directory.appendingPathComponent("captions.srt")
            try Data("1\n00:00:01,000 --> 00:00:02,500\nHello\n".utf8).write(to: srt)
            await check.convert(srt, from: .srt, to: .vtt)

            let unchanged = (try? Data(contentsOf: png)) == originalPNG
            print("\(unchanged ? "PASS" : "FAIL") source file unchanged")
            let passed = check.allPassed && unchanged
            print(passed ? "SELFTEST OK" : "SELFTEST FAILED")
            return passed
        } catch {
            print("FAIL setup: \(error.localizedDescription)")
            return false
        }
    }

    struct Checker {
        let runner: WorkerRunner
        let directory: URL
        var allPassed = true

        /// Converts and verifies the output's format by its contents. Returns the output on success.
        @discardableResult
        mutating func convert(_ input: URL, from source: FileFormat, to target: FileFormat) async -> URL? {
            let destination = OutputPlanner.destination(for: input, target: target, in: directory)
            let label = "\(source.rawValue) -> \(target.rawValue)"
            do {
                let result = try await runner.run(
                    input: input, destination: destination,
                    request: ConversionRequest(source: source, target: target)
                )
                let expected = target == .alac ? FileFormat.m4a : target
                let detected = FileFormat.detect(at: destination)
                guard detected == expected, result.outputBytes > 0 else {
                    print("FAIL \(label): output detected as \(detected?.rawValue ?? "unknown")")
                    allPassed = false
                    return nil
                }
                print("PASS \(label): \(result.outputBytes) bytes \(result.notes.map(\.rawValue))")
                return destination
            } catch {
                print("FAIL \(label): \(error.localizedDescription)")
                allPassed = false
                return nil
            }
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

    /// One second of a 440 Hz stereo tone, 16-bit 44.1 kHz.
    private static func writeTone(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<44_100 { samples[frame] = 0.3 * sin(2 * .pi * 440 * Float(frame) / 44_100) }
        }
        try file.write(from: buffer)
    }
}
