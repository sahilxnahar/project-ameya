import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO

/// Self-test checks for the privacy check, cleaning, photo details, checksums and batch rename,
/// through the real sandboxed worker.
extension SelfTest.Checker {
    mutating func checkPrivacy() async {
        let catalog = ToolCatalog(writable: FileFormat.systemWritable())
        guard let clean = catalog.tools.first(where: { $0.id == "privacy.check" }) else {
            privacyReport(false, "privacy tools registered", "privacy.check is missing")
            return
        }
        do {
            // A photo taken "in London" on a camera with a serial number.
            let photo = directory.appendingPathComponent("london.jpg")
            try SelfTest.privatePhoto().write(to: photo)
            if let report = await inspect(photo, .jpeg) {
                privacyReport(report.findings.contains { $0.group == .location && $0.value == "51.50070, -0.12460" }
                              && report.findings.contains { $0.value == "SN-4815162342" },
                              "photo privacy check", "found \(report.findings.map(\.value))")
            }
            let cleanedPhoto = directory.appendingPathComponent("london (cleaned).jpg")
            if await run(clean.makeRequest(.jpeg), photo, to: cleanedPhoto, "remove photo details"),
               let after = await inspect(cleanedPhoto, .jpeg) {
                privacyReport(!after.findings.contains { [.location, .name, .device].contains($0.group) },
                              "photo cleaned (re-checked)", "still has \(after.findings.map(\.value))")
            }

            // A PDF with an author.
            let pdf = directory.appendingPathComponent("plans.pdf")
            try SelfTest.authoredPDF().write(to: pdf)
            if let report = await inspect(pdf, .pdf) {
                privacyReport(report.findings.contains { $0.group == .name && $0.value == "Jane Doe" },
                              "PDF privacy check", "found \(report.findings.map(\.value))")
            }
            let cleanedPDF = directory.appendingPathComponent("plans (cleaned).pdf")
            if await run(clean.makeRequest(.pdf), pdf, to: cleanedPDF, "remove PDF details"),
               let after = await inspect(cleanedPDF, .pdf) {
                privacyReport(!after.findings.contains { $0.value.contains("Jane") }, "PDF cleaned (re-checked)",
                              "still has \(after.findings.map(\.value))")
            }

            // Shift the camera clock back three hours.
            var options = ConversionOptions()
            options.task = .editDetails(PhotoDetailsEdit(date: .shift(hours: -3), author: "Self Test"))
            let shifted = directory.appendingPathComponent("london (details).jpg")
            if await run(ConversionRequest(source: .jpeg, target: .jpeg, options: options), photo, to: shifted, "edit photo details"),
               let after = await inspect(shifted, .jpeg) {
                privacyReport(after.facts.dateTaken == "2024:05:01 07:30:00" && after.findings.contains { $0.value == "Self Test" },
                              "photo date shifted", "date is \(after.facts.dateTaken ?? "missing")")
            }

            // Checksum of "abc" (FIPS 180 test vector), then verify it in plain words.
            let abc = directory.appendingPathComponent("abc.txt")
            try Data("abc".utf8).write(to: abc)
            var sums = ConversionOptions()
            sums.task = .checksum(ChecksumAlgorithm.allCases)
            let json = directory.appendingPathComponent("abc (checksum).json")
            if await run(ConversionRequest(source: .txt, target: .json, options: sums), abc, to: json, "checksum"),
               let report = try? ChecksumReport.decode(Data(contentsOf: json)) {
                let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
                privacyReport(report[.sha256] == expected && report[.md5] == "900150983cd24fb0d6963f7d28e17f72"
                              && ChecksumMatch.compare(pasted: expected.uppercased(), with: report) == .match(.sha256),
                              "checksum and verify", "got \(report.digests)")
            }

            // Batch rename makes copies and never overwrites.
            let names = RenamePlanner.newNames(for: [RenameItem(name: "london.jpg"), RenameItem(name: "plans.pdf")],
                                               rule: RenameRule(pattern: "Trip {n:2}")) {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
            let copies = directory.appendingPathComponent("renamed", isDirectory: true)
            let outcome = await RenameApplier.copy([photo, pdf], as: names, into: copies)
            let copied = names.allSatisfy { FileManager.default.fileExists(atPath: copies.appendingPathComponent($0).path) }
            privacyReport(outcome.done == 2 && copied && names == ["Trip 01.jpg", "Trip 02.pdf"]
                          && FileManager.default.fileExists(atPath: photo.path), "batch rename copies", "made \(names)")
        } catch {
            privacyReport(false, "privacy setup", error.localizedDescription)
        }
    }

    private mutating func inspect(_ url: URL, _ format: FileFormat) async -> PrivacyReport? {
        var options = ConversionOptions()
        options.task = .inspect
        let destination = directory.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) report \(UUID().uuidString).json")
        guard await run(ConversionRequest(source: format, target: .json, options: options), url, to: destination, "inspect \(url.lastPathComponent)") else {
            return nil
        }
        do {
            return try PrivacyReport.decode(Data(contentsOf: destination))
        } catch {
            privacyReport(false, "read report", error.localizedDescription)
            return nil
        }
    }

    private mutating func run(_ request: ConversionRequest, _ input: URL, to destination: URL, _ label: String) async -> Bool {
        do {
            _ = try await runner.run(input: input, destination: destination, request: request)
            return true
        } catch {
            privacyReport(false, label, error.localizedDescription)
            return false
        }
    }

    private mutating func privacyReport(_ passed: Bool, _ label: String, _ problem: String) {
        print(passed ? "PASS privacy \(label)" : "FAIL privacy \(label): \(problem)")
        if !passed { allPassed = false }
    }
}

extension SelfTest {
    static func privatePhoto() throws -> Data {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw CocoaError(.featureUnsupported)
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 51.5007, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.1246, kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:30:00",
                kCGImagePropertyExifBodySerialNumber: "SN-4815162342",
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS R5"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    static func authoredPDF() throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let info: [CFString: Any] = [kCGPDFContextAuthor: "Jane Doe", kCGPDFContextCreator: "SecretApp 1.0"]
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else {
            throw CocoaError(.featureUnsupported)
        }
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 20, y: 20, width: 40, height: 40))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
