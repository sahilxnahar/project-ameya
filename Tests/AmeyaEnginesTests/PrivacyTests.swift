import AmeyaCore
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import AmeyaEngines

/// Privacy check, hidden-detail removal, photo details and checksums, through `Engine.run`.
@MainActor
struct PrivacyTests {
    /// Runs a task the way the worker does and returns the output file.
    func run(_ task: FileTask, _ input: URL, source: FileFormat?, target: FileFormat) async throws -> (URL, ConversionResult) {
        let scratch = try PrivacyFixtures.directory()
        var options = ConversionOptions()
        options.task = task
        let (outputs, result) = try await Engine.run(inputs: [input], request: ConversionRequest(source: source, target: target, options: options),
                                                     scratch: scratch) { _ in }
        return (outputs[0], result)
    }

    func inspect(_ input: URL, source: FileFormat?) async throws -> PrivacyReport {
        let (output, _) = try await run(.inspect, input, source: source, target: .json)
        return try PrivacyReport.decode(Data(contentsOf: output))
    }

    func values(_ report: PrivacyReport) -> String {
        report.findings.map { "\($0.group.rawValue):\($0.label)=\($0.value)" }.joined(separator: "\n")
    }

    // MARK: Photos

    @Test func photoReportFindsLocationNameAndDevice() async throws {
        let photo = try PrivacyFixtures.photo(in: try PrivacyFixtures.directory())
        let report = try await inspect(photo, source: .jpeg)
        let text = values(report)
        #expect(report.kind == .photo && report.canClean)
        #expect(report.findings.contains { $0.group == .location && $0.value == "51.50070, -0.12460" }, "\(text)")
        #expect(report.findings.contains { $0.group == .device && $0.value == "SN-4815162342" }, "\(text)")
        #expect(report.findings.contains { $0.group == .name && $0.value == "Jane Doe" }, "\(text)")
        #expect(report.findings.contains { $0.group == .edits && $0.value == "PhotoFixer 2" }, "\(text)")
        #expect(report.facts == PrivacyReport.Facts(width: 64, height: 48, dateTaken: "2024:05:01 10:30:00", camera: "Canon EOS R5"))
    }

    @Test func cleaningAPhotoReallyRemovesEverything() async throws {
        let photo = try PrivacyFixtures.photo(in: try PrivacyFixtures.directory())
        let (cleaned, _) = try await run(.clean, photo, source: .jpeg, target: .jpeg)
        let report = try await inspect(cleaned, source: .jpeg)
        let text = values(report)
        #expect(!report.findings.contains { [.location, .name, .device].contains($0.group) }, "\(text)")
        #expect(!text.contains("SN-4815162342") && !text.contains("Jane"), "\(text)")
    }

    @Test func editDetailsShiftsDatesAndWritesFieldsWithoutReencoding() async throws {
        let photo = try PrivacyFixtures.photo(in: try PrivacyFixtures.directory())
        let edit = PhotoDetailsEdit(date: .shift(hours: -3), title: "Big Ben", description: "A clock",
                                    author: "Ameya Tester", copyright: "© 2024 Tester", keywords: ["london", "clock"])
        let (output, result) = try await run(.editDetails(edit), photo, source: .jpeg, target: .jpeg)
        #expect(result.notes == [.photoDetailsUpdated])
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2024:05:01 07:30:00")
        #expect(tiff[kCGImagePropertyTIFFArtist] as? String == "Ameya Tester")
        #expect(tiff[kCGImagePropertyTIFFCopyright] as? String == "© 2024 Tester")
        #expect(iptc[kCGImagePropertyIPTCObjectName] as? String == "Big Ben")
        #expect(iptc[kCGImagePropertyIPTCKeywords] as? [String] == ["london", "clock"])
        // Untouched details stay.
        #expect((properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])?[kCGImagePropertyGPSLatitude] != nil)
    }

    @Test func editDetailsCanSetADateAndRemoveAnAuthor() async throws {
        let photo = try PrivacyFixtures.photo(in: try PrivacyFixtures.directory())
        let (output, _) = try await run(.editDetails(PhotoDetailsEdit(date: .set("2020:01:02 03:04:05"), author: "")),
                                        photo, source: .jpeg, target: .jpeg)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2020:01:02 03:04:05")
        #expect(tiff[kCGImagePropertyTIFFArtist] == nil)
    }

    // MARK: PDFs

    @Test func pdfReportAndCleaning() async throws {
        let pdf = try PrivacyFixtures.pdf(in: try PrivacyFixtures.directory())
        let report = try await inspect(pdf, source: .pdf)
        let text = values(report)
        #expect(report.kind == .pdf && report.canClean)
        #expect(text.contains("name:Author=Jane Doe") && text.contains("Jane XMP") && text.contains("SecretApp 1.0"), "\(text)")
        #expect(text.contains("XMP Tool 9"), "\(text)")

        let (cleaned, result) = try await run(.clean, pdf, source: .pdf, target: .pdf)
        #expect(result.notes.contains(.hiddenDetailsRemoved))
        #expect(PDFDocument(url: cleaned)?.pageCount == 1)
        let after = values(try await inspect(cleaned, source: .pdf))
        #expect(!after.contains("Jane") && !after.contains("SecretApp") && !after.contains("XMP"), "\(after)")
    }

    @Test func countsIncrementalSaves() throws {
        let directory = try PrivacyFixtures.directory()
        let url = directory.appendingPathComponent("saves.pdf")
        try Data("%PDF-1.4\n...%%EOF\nmore%%EOF\n".utf8).write(to: url)
        #expect(PDFPrivacy.countSaves(url) == 2)
        #expect(PDFValue.readableDate("D:20240501103000+01'00'") == "2024-05-01 10:30")
    }

    // MARK: Office

    @Test func wordReportAndCleaning() async throws {
        let docx = try PrivacyFixtures.docx(in: try PrivacyFixtures.directory())
        let report = try await inspect(docx, source: .docx)
        let text = values(report)
        #expect(report.kind == .office && report.canClean)
        for expected in ["name:Author=Jane Doe", "name:Last changed by=John Smith", "name:Company=Acme Secret Labs",
                         "name:Comment authors=Bob Reviewer", "other:Comments=1 comment", "Megacorp", "edits:Editing-session IDs"] {
            #expect(text.contains(expected), "missing \(expected) in \(text)")
        }

        let (cleaned, result) = try await run(.clean, docx, source: .docx, target: .docx)
        #expect(result.notes == [.hiddenDetailsRemoved])
        let after = try await inspect(cleaned, source: .docx)
        #expect(after.findings.isEmpty, "\(values(after))")
        // The package still holds the document, and nothing points at removed parts.
        let entries = try ArchiveEntries.read(cleaned)
        #expect(entries["word/document.xml"].map { String(decoding: $0, as: UTF8.self).contains("Hello") } == true)
        #expect(entries["word/comments.xml"] == nil && entries["docProps/custom.xml"] == nil)
        let all = entries.paths.compactMap { entries[$0] }.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(!all.contains("comments.xml") && !all.contains("custom.xml") && !all.contains("rsid") && !all.contains("commentRe"))
    }

    @Test func relationshipTargetsResolve() {
        #expect(OfficeCleaner.resolve("comments.xml", base: "word") == "word/comments.xml")
        #expect(OfficeCleaner.resolve("../docProps/custom.xml", base: "word") == "docProps/custom.xml")
        #expect(OfficeCleaner.resolve("/word/people.xml", base: "") == "word/people.xml")
    }

    // MARK: Sound and video

    @Test func videoLocationIsFoundAndRemoved() async throws {
        let clip = try await PrivacyFixtures.video(in: try PrivacyFixtures.directory())
        let report = try await inspect(clip, source: .mp4)
        let text = values(report)
        #expect(report.kind == .media && report.canClean)
        #expect(report.findings.contains { $0.group == .location && $0.value == "48.85840, 2.29450" }, "\(text)")

        let (cleaned, _) = try await run(.clean, clip, source: .mp4, target: .mp4)
        let after = try await inspect(cleaned, source: .mp4)
        #expect(!after.findings.contains { [.location, .device].contains($0.group) }, "\(values(after))")
    }

    @Test func quickTimeDeviceIsFoundAndRemoved() async throws {
        let clip = try await PrivacyFixtures.video(in: try PrivacyFixtures.directory(), as: .mov)
        let report = try await inspect(clip, source: .mov)
        let text = values(report)
        #expect(report.findings.contains { $0.group == .location && $0.value == "48.85840, 2.29450" }, "\(text)")
        #expect(report.findings.contains { $0.group == .device && $0.value == "iPhone 15 Pro" }, "\(text)")

        let (cleaned, _) = try await run(.clean, clip, source: .mov, target: .mov)
        let after = try await inspect(cleaned, source: .mov)
        #expect(!after.findings.contains { [.location, .device, .edits].contains($0.group) }, "\(values(after))")
    }

    @Test func iso6709() {
        #expect(MediaPrivacy.iso6709("-33.8568+151.2153/") == "-33.85680, 151.21530")
        #expect(MediaPrivacy.iso6709("nowhere") == nil)
    }

    // MARK: Checksums

    @Test func checksumKnownVectors() async throws {
        let file = try PrivacyFixtures.directory().appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        let (output, _) = try await run(.checksum(ChecksumAlgorithm.allCases), file, source: .txt, target: .json)
        let report = try ChecksumReport.decode(Data(contentsOf: output))
        #expect(report.bytes == 3)
        #expect(report[.sha256] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(report[.sha1] == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(report[.md5] == "900150983cd24fb0d6963f7d28e17f72")

        let empty = file.deletingLastPathComponent().appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        #expect(try FileTasks.checksum(empty, algorithms: [.sha256])[.sha256]
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func unknownFilesGetAnHonestReport() async throws {
        let file = try PrivacyFixtures.directory().appendingPathComponent("blob.bin")
        try Data([0x01, 0x02, 0x03, 0x04]).write(to: file)
        let report = try await inspect(file, source: .other)
        #expect(report.kind == .other && !report.canClean && report.findings.isEmpty)
    }
}
