import Foundation
import Testing
@testable import AmeyaCore

struct DateShiftTests {
    @Test func shiftsAcrossDaysMonthsAndYears() {
        #expect(ExifDate.shifted("2024:05:01 10:30:00", byHours: 3) == "2024:05:01 13:30:00")
        #expect(ExifDate.shifted("2024:05:01 01:00:00", byHours: -2) == "2024:04:30 23:00:00")
        #expect(ExifDate.shifted("2023:12:31 23:30:00", byHours: 1) == "2024:01:01 00:30:00")
        #expect(ExifDate.shifted("2024:02:28 22:00:00", byHours: 24) == "2024:02:29 22:00:00") // leap year
        #expect(ExifDate.shifted("2024:05:01 10:00:00", byHours: 5.5) == "2024:05:01 15:30:00")
    }

    @Test func ignoresDaylightSavingBecauseCameraClocksHaveNoTimeZone() {
        // 31 March 2024 is a DST change in Europe; the wall clock still moves exactly 24 hours.
        #expect(ExifDate.shifted("2024:03:30 12:00:00", byHours: 24) == "2024:03:31 12:00:00")
    }

    @Test func parsesCommonSpellingsAndRejectsJunk() {
        #expect(ExifDate.parse("2024-05-01T10:30:00") == ExifDate.parse("2024:05:01 10:30:00"))
        #expect(ExifDate.parse("not a date") == nil)
        #expect(ExifDate.shifted("", byHours: 1) == nil)
        #expect(ExifDate.format("2024:05:01 10:30:00", as: "yyyy-MM-dd") == "2024-05-01")
    }
}

struct RenamePatternTests {
    let photo = RenameItem(name: "IMG_0001.JPG", dateModified: Date(timeIntervalSince1970: 1_714_557_600),
                           facts: PrivacyReport.Facts(width: 4032, height: 3024, dateTaken: "2024:05:01 10:30:00", camera: "iPhone 15 Pro"))

    @Test func expandsEveryToken() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(RenamePlanner.expand("{date taken:yyyy-MM-dd} {camera} {width}x{height} {n:3}", item: photo, number: 7, timeZone: utc)
                == "2024-05-01 iPhone 15 Pro 4032x3024 007")
        #expect(RenamePlanner.expand("{name}-{date modified}.{ext}", item: photo, number: 1, timeZone: utc) == "IMG_0001-2024-05-01.JPG")
        #expect(RenamePlanner.expand("{n}", item: photo, number: 12) == "12")
        #expect(RenamePlanner.expand("{unknown} {name", item: photo, number: 1) == "{unknown} {name")
        #expect(RenamePlanner.needsFacts("{date taken}") && !RenamePlanner.needsFacts("{name} {n:2}"))
    }

    @Test func keepsTheExtensionAndAppliesFindReplaceAndCase() {
        let rule = RenameRule(pattern: "{name}", find: "img_", replace: "Holiday ", caseChange: .lower)
        #expect(RenamePlanner.newNames(for: [photo], rule: rule) == ["holiday 0001.JPG"])
        #expect(RenamePlanner.newNames(for: [photo], rule: RenameRule(pattern: "trip {n:2}", caseChange: .upper)) == ["TRIP 01.JPG"])
    }

    @Test func neverProducesTheSameNameTwice() {
        let items = ["a.jpg", "b.jpg", "c.JPG"].map { RenameItem(name: $0) }
        let names = RenamePlanner.newNames(for: items, rule: RenameRule(pattern: "Beach")) { $0 == "Beach.jpg" }
        #expect(names == ["Beach 2.jpg", "Beach 3.jpg", "Beach.JPG"])
        // Names differing only in case clash on a Mac disk.
        #expect(RenamePlanner.newNames(for: [RenameItem(name: "a.jpg"), RenameItem(name: "b.JPG")], rule: RenameRule(pattern: "x"))
                == ["x.jpg", "x 2.JPG"])
    }

    @Test func makesSafeNames() {
        let names = RenamePlanner.newNames(for: [RenameItem(name: "x.txt")], rule: RenameRule(pattern: "../a/b:c"))
        #expect(names == ["-a-b-c.txt"])
        // An empty result falls back to the old name rather than an invisible file.
        #expect(RenamePlanner.newNames(for: [RenameItem(name: "x.txt")], rule: RenameRule(pattern: "{camera}")) == ["x.txt"])
    }
}

struct ChecksumMatchTests {
    let report = ChecksumReport(bytes: 3, digests: [
        .sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        .sha1: "a9993e364706816aba3e25717850c26c9cd0d89d",
        .md5: "900150983cd24fb0d6963f7d28e17f72",
    ])

    @Test func recognisesPastedFormats() {
        #expect(ChecksumMatch.compare(pasted: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD", with: report) == .match(.sha256))
        #expect(ChecksumMatch.compare(pasted: "SHA1 (abc.txt) = a9993e364706816aba3e25717850c26c9cd0d89d", with: report) == .match(.sha1))
        #expect(ChecksumMatch.compare(pasted: "900150983cd24fb0d6963f7d28e17f72  abc.txt\n", with: report) == .match(.md5))
        #expect(ChecksumMatch.compare(pasted: "ba7816bf 8f01cfea 414140de 5dae2223 b00361a3 96177a9c b410ff61 f20015ad", with: report) == .match(.sha256))
    }

    @Test func reportsDifferencesAndNonsense() {
        #expect(ChecksumMatch.compare(pasted: String(repeating: "0", count: 64), with: report) == .different(.sha256))
        #expect(ChecksumMatch.compare(pasted: "hello", with: report) == .notAChecksum)
        #expect(ChecksumMatch.different(.sha256).message.hasPrefix("✗ Different"))
    }

    @Test func reportRoundTripsAsJSON() throws {
        #expect(try ChecksumReport.decode(report.encoded()) == report)
    }
}

struct PrivacyReportTests {
    @Test func groupsInOrderAndCleansValues() throws {
        let report = PrivacyReport(kind: .photo, findings: [
            .init(group: .other, label: "Title", value: "Holiday"),
            .init(group: .location, label: "GPS", value: "1, 2\u{0}\n"),
        ], canClean: true)
        #expect(report.grouped.map(\.group) == [.location, .other])
        #expect(report.findings[1].value == "1, 2")
        #expect(try PrivacyReport.decode(report.encoded()) == report)
        #expect(PrivacyReport.clip(String(repeating: "a", count: 500)).count == 300)
    }

    @Test func requestCarriesTheTask() throws {
        var options = ConversionOptions()
        options.task = .editDetails(PhotoDetailsEdit(date: .shift(hours: -2), keywords: ["a"]))
        let request = ConversionRequest(source: .jpeg, target: .jpeg, options: options)
        #expect(try WorkerProtocol.decodeRequest(WorkerProtocol.encode(request)) == request)
        #expect(options.hasEdits)
    }

    @Test func sameKindOutputsKeepTheirExtension() {
        let destination = OutputPlanner.destination(for: URL(fileURLWithPath: "/in/Budget.xlsx"), target: .other,
                                                    in: URL(fileURLWithPath: "/out"), suffix: "(cleaned)") { _ in false }
        #expect(destination.lastPathComponent == "Budget (cleaned).xlsx")
    }
}
