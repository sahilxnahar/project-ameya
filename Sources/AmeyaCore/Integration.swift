import Foundation

// Pure logic behind the macOS integrations (open-with, Services, clipboard, the Downloads
// watcher). Kept here, free of AppKit, so it can be unit-tested.

/// Which URLs handed to the app (Dock drop, "Open With", Services, clipboard) become pending files.
public enum OpenedFiles {
    /// Keeps regular local files, in order, without duplicates. Folders, packages, remote URLs
    /// and missing files are dropped; the caller decides whether each remaining file is supported.
    public static func accepted(_ urls: [URL], fileManager: FileManager = .default) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls where url.isFileURL {
            let standard = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standard.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  seen.insert(standard.path).inserted else { continue }
            result.append(url)
        }
        return result
    }
}

/// Image data found on the clipboard, and the temporary file it is written to.
public enum ClipboardImage {
    /// Pasteboard types Ameya reads as an image, best first. Original encoded data is preferred
    /// over TIFF, which apps add as a lossless fallback representation.
    public static let preferredTypes: [(type: String, format: FileFormat)] = [
        ("public.png", .png),
        ("public.jpeg", .jpeg),
        ("public.heic", .heic),
        ("org.webmproject.webp", .webp),
        ("com.compuserve.gif", .gif),
        ("com.adobe.pdf", .pdf),
        ("public.tiff", .tiff),
    ]

    /// The best image representation among the pasteboard's available types, if any.
    public static func bestType(among available: [String]) -> (type: String, format: FileFormat)? {
        preferredTypes.first { available.contains($0.type) }
    }

    /// "Clipboard 2026-10-21 at 14.03.05.png". Uses no characters Finder or the sandbox dislike.
    public static func fileName(for format: FileFormat, date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d-%02d-%02d at %02d.%02d.%02d",
                           c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return "Clipboard \(stamp).\(format.preferredExtension)"
    }

    /// A file URL in `directory` for clipboard data that doesn't collide with an existing file.
    public static func temporaryURL(for format: FileFormat, date: Date, in directory: URL,
                                    isTaken: (URL) -> Bool) -> URL {
        let name = fileName(for: format, date: date)
        let base = (name as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while isTaken(candidate) {
            candidate = directory.appendingPathComponent("\(base) \(counter).\(format.preferredExtension)")
            counter += 1
        }
        return candidate
    }
}

/// Coalesces bursts of file-system events into one scan.
public struct Debouncer: Sendable {
    public let delay: TimeInterval
    public private(set) var deadline: Date?

    public init(delay: TimeInterval) {
        self.delay = delay
    }

    /// Records an event. Returns the time the scan should run: each event pushes it back.
    public mutating func signal(at now: Date) -> Date {
        let next = now.addingTimeInterval(delay)
        deadline = next
        return next
    }

    /// Whether the scan is due. Clears the deadline when it fires, so it fires once per burst.
    public mutating func fire(at now: Date) -> Bool {
        guard let deadline, now >= deadline else { return false }
        self.deadline = nil
        return true
    }
}

/// One file seen while scanning a watched folder.
public struct WatchedFile: Equatable, Sendable {
    public let url: URL
    public let size: Int64

    public init(url: URL, size: Int64) {
        self.url = url
        self.size = size
    }
}

/// Decides when a new file in a watched folder is complete and should be converted.
///
/// A file is ready once its size has been non-zero and unchanged for `stableFor` seconds.
/// Files present when watching started, files already handed out, files Ameya wrote itself,
/// hidden files and files that aren't eligible (wrong extension) are never returned.
public struct StabilityTracker: Sendable {
    public let stableFor: TimeInterval
    public let extensions: Set<String>
    private var baseline: Set<String> = []
    private var handled: Set<String> = []
    private var produced: Set<String> = []
    private var observations: [String: (size: Int64, since: Date)] = [:]

    public init(stableFor: TimeInterval = 2, extensions: Set<String> = ["heic", "heif"]) {
        self.stableFor = stableFor
        self.extensions = Set(extensions.map { $0.lowercased() })
    }

    /// Files already in the folder when watching starts are left alone.
    public mutating func setBaseline(_ files: [WatchedFile]) {
        baseline = Set(files.map { Self.key($0.url) })
    }

    /// Marks a path Ameya is about to write, so it is never treated as a new download.
    public mutating func markProduced(_ url: URL) {
        produced.insert(Self.key(url))
    }

    public func isEligible(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix(".") else { return false }
        return extensions.contains(url.pathExtension.lowercased())
    }

    /// Whether any eligible file is still settling, so the caller should scan again soon.
    public var hasCandidates: Bool { !observations.isEmpty }

    /// Feeds one scan of the folder. Returns the files that just became ready.
    public mutating func update(_ files: [WatchedFile], now: Date) -> [URL] {
        var ready: [URL] = []
        var present: Set<String> = []
        for file in files where isEligible(file.url) {
            let key = Self.key(file.url)
            present.insert(key)
            guard !baseline.contains(key), !handled.contains(key), !produced.contains(key) else { continue }
            if let previous = observations[key], previous.size == file.size {
                if file.size > 0, now.timeIntervalSince(previous.since) >= stableFor {
                    observations[key] = nil
                    handled.insert(key)
                    ready.append(file.url)
                }
            } else {
                observations[key] = (file.size, now)
            }
        }
        // Forget files that disappeared (moved away, renamed after a partial download).
        for key in observations.keys where !present.contains(key) {
            observations[key] = nil
        }
        return ready
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
