import Foundation
import Testing
@testable import AmeyaCore

@Suite("Opened files")
struct OpenedFilesTests {
    @Test("Keeps existing regular files once, in order; drops folders, missing and remote URLs")
    func filtering() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.png"), b = dir.appendingPathComponent("b.heic")
        try Data([1]).write(to: a)
        try Data([2]).write(to: b)
        let folder = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let result = OpenedFiles.accepted([
            b, a, URL(fileURLWithPath: dir.path + "/./a.png"), folder,
            dir.appendingPathComponent("missing.jpg"), URL(string: "https://example.com/x.png")!,
        ])
        #expect(result.map(\.lastPathComponent) == ["b.heic", "a.png"])
    }
}

@Suite("Clipboard image")
struct ClipboardImageTests {
    @Test("Prefers original encoded data over TIFF")
    func bestType() {
        #expect(ClipboardImage.bestType(among: ["public.tiff", "public.png"])?.format == .png)
        #expect(ClipboardImage.bestType(among: ["public.tiff", "public.jpeg"])?.format == .jpeg)
        #expect(ClipboardImage.bestType(among: ["public.tiff"])?.format == .tiff)
        #expect(ClipboardImage.bestType(among: ["public.utf8-plain-text"]) == nil)
    }

    @Test("Names are dated, safe and never collide")
    func naming() {
        let date = Date(timeIntervalSince1970: 1_792_576_985) // 2026-10-21 10:03:05 UTC
        let utc = TimeZone(identifier: "UTC")!
        #expect(ClipboardImage.fileName(for: .png, date: date, timeZone: utc) == "Clipboard 2026-10-21 at 10.03.05.png")
        let name = ClipboardImage.fileName(for: .jpeg, date: date)
        #expect(!name.contains("/") && !name.contains(":"))
        #expect(name.hasSuffix(".jpg"))

        let dir = URL(fileURLWithPath: "/tmp/clip")
        var taken: Set<String> = []
        for _ in 0..<3 {
            let url = ClipboardImage.temporaryURL(for: .png, date: date, in: dir) { taken.contains($0.lastPathComponent) }
            #expect(taken.insert(url.lastPathComponent).inserted)
        }
        #expect(taken.contains { $0.hasSuffix(" 3.png") })
    }
}

@Suite("Downloads watcher")
struct WatcherTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let dir = URL(fileURLWithPath: "/Users/me/Downloads")

    func file(_ name: String, _ size: Int64) -> WatchedFile {
        WatchedFile(url: dir.appendingPathComponent(name), size: size)
    }

    @Test("Debounce: each event pushes the deadline back; fires once")
    func debounce() {
        var debouncer = Debouncer(delay: 0.5)
        _ = debouncer.signal(at: t0)
        let deadline = debouncer.signal(at: t0 + 0.3)
        #expect(deadline == t0 + 0.8)
        let early = debouncer.fire(at: t0 + 0.6)
        let due = debouncer.fire(at: t0 + 0.8)
        let again = debouncer.fire(at: t0 + 2)
        #expect(!early && due && !again)
    }

    @Test("A file is ready only after its size is stable for two seconds")
    func stability() {
        var tracker = StabilityTracker()
        do { let r = tracker.update([file("IMG_1.HEIC", 100)], now: t0); #expect(r.isEmpty) }
        do { let r = tracker.update([file("IMG_1.HEIC", 500)], now: t0 + 1); #expect(r.isEmpty) }   // still growing
        do { let r = tracker.update([file("IMG_1.HEIC", 500)], now: t0 + 2); #expect(r.isEmpty) }   // stable 1 s
        #expect(tracker.hasCandidates)
        let ready = tracker.update([file("IMG_1.HEIC", 500)], now: t0 + 3)        // stable 2 s
        #expect(ready.map(\.lastPathComponent) == ["IMG_1.HEIC"])
        do { let r = tracker.update([file("IMG_1.HEIC", 500)], now: t0 + 10); #expect(r.isEmpty) }  // only once
        #expect(!tracker.hasCandidates)
    }

    @Test("Empty files wait; baseline, produced, hidden and other types are skipped")
    func skipping() {
        var tracker = StabilityTracker()
        tracker.setBaseline([file("old.heic", 10)])
        tracker.markProduced(dir.appendingPathComponent("mine.heic"))
        let files = [file("old.heic", 10), file("mine.heic", 10), file(".hidden.heic", 10),
                     file("photo.jpg", 10), file("empty.heif", 0), file("new.heif", 10)]
        _ = tracker.update(files, now: t0)
        let ready = tracker.update(files, now: t0 + 5)
        #expect(ready.map(\.lastPathComponent) == ["new.heif"])
    }

    @Test("Files that disappear while settling are forgotten")
    func disappearing() {
        var tracker = StabilityTracker()
        _ = tracker.update([file("a.heic", 10)], now: t0)
        _ = tracker.update([], now: t0 + 1)
        #expect(!tracker.hasCandidates)
        // Reappearing restarts the clock.
        do { let r = tracker.update([file("a.heic", 10)], now: t0 + 2); #expect(r.isEmpty) }
        do { let r = tracker.update([file("a.heic", 10)], now: t0 + 3); #expect(r.isEmpty) }
        do { let r = tracker.update([file("a.heic", 10)], now: t0 + 4); #expect(r.count == 1) }
    }
}
