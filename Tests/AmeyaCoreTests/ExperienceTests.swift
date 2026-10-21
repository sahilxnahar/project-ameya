import Foundation
import Testing
@testable import AmeyaCore

@Suite("Size savings wording")
struct SizeChangeTests {
    @Test("Percentages read naturally", arguments: [
        (Int64(1000), Int64(380), "62% smaller"),
        (1000, 995, "About the same size"),
        (1000, 1005, "About the same size"),
        (1000, 1180, "18% bigger"),
        (1000, 3000, "3× bigger"),
        (1000, 2500, "2.5× bigger"),
        (1000, 42_000, "42× bigger"),
        (1000, 0, "100% smaller"),
        (0, 500, "About the same size"),
    ])
    func wording(before: Int64, after: Int64, expected: String) {
        #expect(SizeChange(before: before, after: after).description == expected)
    }

    @Test func tinyOutputNeverClaimsAHundredPercent() {
        #expect(SizeChange(before: 10_000_000, after: 10).direction == .smaller(percent: 99))
    }

    @Test func spokenVersionHasBothSizes() {
        let spoken = SizeChange(before: 2_000_000, after: 500_000).spoken
        #expect(spoken.contains("before"))
        #expect(spoken.contains("after"))
        #expect(spoken.hasSuffix("75% smaller"))
    }
}

@Suite("Batch headline")
struct BatchSummaryTests {
    @Test func savingsHeadline() {
        let summary = BatchSummary([.done(before: 10_000_000, after: 4_000_000), .done(before: 2_000_000, after: 1_000_000)])
        #expect(summary.succeeded == 2)
        #expect(summary.saved == 7_000_000)
        #expect(summary.headline.hasPrefix("Done! 2 files, "))
        #expect(summary.headline.hasSuffix(" smaller"))
        #expect(summary.isCelebration)
    }

    @Test func biggerFilesDontBoastAboutSavings() {
        let summary = BatchSummary([.done(before: 100, after: 900)])
        #expect(summary.headline == "Done! 1 file ready")
    }

    @Test func failuresAreNamedHonestly() {
        #expect(BatchSummary([.failed]).headline == "That one didn't work. The reason is below.")
        #expect(BatchSummary([.failed, .failed]).headline.hasPrefix("None of those worked"))
        let mixed = BatchSummary([.done(before: 1, after: 1), .failed, .cancelled])
        #expect(mixed.headline == "1 done, 1 didn't work. Details are below.")
        #expect(!mixed.isCelebration)
    }

    @Test func reduceMotionAlwaysWins() {
        let good = BatchSummary([.done(before: 2, after: 1)])
        #expect(CelebrationPolicy.shouldCelebrate(setting: true, reduceMotion: false, summary: good))
        #expect(!CelebrationPolicy.shouldCelebrate(setting: true, reduceMotion: true, summary: good))
        #expect(!CelebrationPolicy.shouldCelebrate(setting: false, reduceMotion: false, summary: good))
        #expect(!CelebrationPolicy.shouldCelebrate(setting: true, reduceMotion: false, summary: BatchSummary([.failed])))
    }
}

@Suite("Undo safety")
struct UndoCheckTests {
    @Test func onlyTheUntouchedFileCanBeUndone() {
        #expect(UndoCheck.canMoveToTrash(exists: true, currentBytes: 42, recordedBytes: 42))
        #expect(!UndoCheck.canMoveToTrash(exists: false, currentBytes: nil, recordedBytes: 42))
        #expect(!UndoCheck.canMoveToTrash(exists: true, currentBytes: 43, recordedBytes: 42))
        #expect(UndoCheck.canMoveToTrash(exists: true, currentBytes: nil, recordedBytes: 42))
    }
}

@Suite("Recent files")
struct RecentFilesTests {
    @Test func newestFirstWithoutDuplicates() {
        var list = RecentList()
        list.add(RecentFile(path: "/a.jpg", bytesBefore: 10, bytesAfter: 5))
        list.add(RecentFile(path: "/b.png", bytesBefore: 10, bytesAfter: 5))
        list.add(RecentFile(path: "/a.jpg", bytesBefore: 20, bytesAfter: 6))
        #expect(list.items.map(\.path) == ["/a.jpg", "/b.png"])
        #expect(list.items[0].bytesBefore == 20)
        list.remove(path: "/a.jpg")
        #expect(list.items.map(\.path) == ["/b.png"])
        list.clear()
        #expect(list.items.isEmpty)
    }

    @Test func isCapped() {
        var list = RecentList()
        for index in 0..<(RecentList.limit + 5) {
            list.add(RecentFile(path: "/\(index)", bytesBefore: 1, bytesAfter: 1))
        }
        #expect(list.items.count == RecentList.limit)
        #expect(list.items.first?.path == "/\(RecentList.limit + 4)")
    }

    @Test func survivesASaveAndLoad() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-recent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RecentStore(url: folder.appendingPathComponent("recent.json"))
        #expect(store.load().items.isEmpty)
        var list = RecentList()
        list.add(RecentFile(path: "/x/one.pdf", bytesBefore: 100, bytesAfter: 40))
        list.add(RecentFile(path: "/x/pages", bytesBefore: 100, bytesAfter: 90, isFolder: true))
        try store.save(list)
        #expect(store.load() == list)

        // Only paths and sizes are stored.
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        let first = try #require((json["items"] as? [[String: Any]])?.first)
        #expect(Set(first.keys) == ["path", "bytesBefore", "bytesAfter", "isFolder"])
    }

    @Test func damagedFileIsAnEmptyList() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-recent-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        #expect(RecentStore(url: url).load().items.isEmpty)
    }
}

@Suite("Convert-to choices")
struct FormatChoicesTests {
    @Test func photoTargetsComeFirstAndMostLikelyFirst() {
        let targets: [FileFormat] = [.tiff, .pdf, .png, .jpeg, .webp, .gif, .bmp, .avif, .jp2, .ico, .icns, .tga]
        let choices = FormatChoices(targets: targets, sources: [.heic])
        #expect(choices.main.first?.kind == .photos)
        #expect(Array(choices.main[0].formats.prefix(2)) == [.jpeg, .png])
        // Nothing lost: every target appears exactly once.
        #expect(choices.all.sorted { $0.rawValue < $1.rawValue } == targets.sorted { $0.rawValue < $1.rawValue })
        // Specialist formats wait behind "More formats".
        #expect(choices.more.flatMap(\.formats).contains(.ico))
        #expect(!choices.main.flatMap(\.formats).contains(.jp2))
    }

    @Test func videoSourcesOfferAudioNext() {
        let targets: [FileFormat] = [.mov, .m4v, .mp4, .m4a, .wav, .gif, .aiff, .alac, .caf, .txt, .srt]
        let choices = FormatChoices(targets: targets, sources: [.mov])
        #expect(choices.main.map(\.kind).prefix(2) == [.video, .audio])
    }

    @Test func shortListsAreNotHidden() {
        let choices = FormatChoices(targets: [.txt, .rtf, .ico], sources: [.pdf])
        #expect(choices.more.isEmpty)
        #expect(choices.all.count == 3)
    }

    @Test func emptyTargetsMeanNoChoices() {
        #expect(FormatChoices(targets: [], sources: [.jpeg]).isEmpty)
    }
}

@Suite("Format search")
struct FormatSearchTests {
    @Test("Everyday words find formats", arguments: [
        ("jpg", FileFormat.jpeg), ("JPEG", .jpeg), (".png", .png), ("word", .docx), ("excel", .xlsx),
        ("music", .mp3), ("iphone", .heic), ("subtitles", .srt), ("gif", .gif), ("ani", .gif),
    ])
    func finds(query: String, format: FileFormat) {
        #expect(FormatSearch.matches(format, query: query))
    }

    @Test func filterKeepsOrderAndExcludesMisses() {
        let formats: [FileFormat] = [.jpeg, .png, .pdf, .mp3]
        #expect(FormatSearch.filter(formats, query: "  ") == formats)
        #expect(FormatSearch.filter(formats, query: "mp") == [.mp3])
        #expect(FormatSearch.filter(formats, query: "pdf") == [.pdf])
        #expect(FormatSearch.filter(formats, query: "zzz").isEmpty)
    }
}
