import Foundation

/// The three wheels: what you can do with files you're dragging.
public enum WheelRing: String, CaseIterable, Sendable, Codable {
    /// "Convert to…": the likeliest target formats.
    case convert
    /// "Tools": Make it smaller, Remove location, Combine into one PDF, …
    case tools
    /// "Actions": Open in Ameya, Copy path, Show in Finder.
    case actions

    public var title: String {
        switch self {
        case .convert: "Convert to…"
        case .tools: "Tools"
        case .actions: "Actions"
        }
    }

    /// What VoiceOver calls it: "Convert wheel, 6 choices".
    public func announcement(choices: Int) -> String {
        let name = switch self {
        case .convert: "Convert wheel"
        case .tools: "Tools wheel"
        case .actions: "Actions wheel"
        }
        return choices == 1 ? "\(name), 1 choice" : "\(name), \(choices) choices"
    }
}

/// A modifier key the user can hold while dragging. Independent of AppKit so it can be tested.
public enum WheelModifier: String, CaseIterable, Sendable, Codable, Comparable {
    // Declared in the order macOS writes them: ⌃ ⌥ ⇧ ⌘, then Fn (Globe).
    case control, option, shift, command, function

    public var symbol: String {
        switch self {
        case .shift: "⇧"
        case .command: "⌘"
        case .control: "⌃"
        case .option: "⌥"
        case .function: "fn"
        }
    }

    public var title: String {
        switch self {
        case .shift: "Shift"
        case .command: "Command"
        case .control: "Control"
        case .option: "Option"
        case .function: "Fn (Globe)"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Apps where the wheel never appears, because they use modifier-drags themselves (design and
/// CAD apps). Matched by bundle identifier, ignoring case.
public struct WheelExclusions: Sendable, Equatable {
    public private(set) var bundleIDs: [String]

    public init(_ bundleIDs: [String] = []) {
        var seen: Set<String> = []
        self.bundleIDs = bundleIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    public func excludes(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return false }
        return bundleIDs.contains { $0.lowercased() == id }
    }

    public func adding(_ bundleID: String) -> WheelExclusions { WheelExclusions(bundleIDs + [bundleID]) }

    public func removing(_ bundleID: String) -> WheelExclusions {
        WheelExclusions(bundleIDs.filter { $0.lowercased() != bundleID.lowercased() })
    }
}

/// Picks the few target formats worth a wedge for the files being dragged.
public enum WheelTargetRanker {
    /// The most wedges a wheel shows; more than this gets hard to aim at.
    public static let maxWedges = 8

    /// Formats people most often want, by the family of the file they start from.
    static func preference(for family: FileFormat.Family) -> [FileFormat] {
        switch family {
        case .image: [.jpeg, .png, .pdf, .heic, .webp, .gif, .tiff, .avif, .txt]
        case .document: [.pdf, .docx, .txt, .md, .html, .epub, .png, .jpeg, .rtf, .odt]
        case .audio: [.mp3, .m4a, .wav, .alac, .flac, .aiff, .txt, .srt]
        case .video: [.mp4, .mov, .gif, .m4a, .mp3, .srt, .txt, .webm]
        case .subtitle: [.srt, .vtt, .txt, .ass]
        case .archive: [.zip, .tgz, .sevenZip, .tar]
        case .data: [.csv, .json, .xlsx, .yaml, .html, .md, .plist, .xml]
        case .contacts: [.csv, .json]
        case .geo: [.gpx, .kml, .geojson, .csv]
        case .model: [.usdz, .obj, .stl, .ply]
        case .compressed: [.gz, .zip, .decompressed]
        }
    }

    /// Up to `limit` of `available` (the targets every dragged file can become), best first.
    ///
    /// A target's score is its average position in each source's preference list; targets no
    /// source family prefers come after, in `available`'s own order. For a mixed selection this
    /// favours formats that suit every file (PDF for pictures and documents together).
    public static func top(_ available: [FileFormat], for sources: [FileFormat], limit: Int = maxWedges) -> [FileFormat] {
        guard limit > 0, !available.isEmpty else { return [] }
        let families = Array(Set(sources.map(\.family))).sorted { $0.rawValue < $1.rawValue }
        let unranked = 1_000.0
        func score(_ target: FileFormat) -> Double {
            guard !families.isEmpty else { return unranked }
            let positions = families.map { family -> Double in
                preference(for: family).firstIndex(of: target).map(Double.init) ?? 50
            }
            let average = positions.reduce(0, +) / Double(positions.count)
            return average >= 50 ? unranked : average
        }
        let ranked = available.enumerated().sorted { lhs, rhs in
            let (a, b) = (score(lhs.element), score(rhs.element))
            return a == b ? lhs.offset < rhs.offset : a < b
        }
        return Array(ranked.prefix(limit).map(\.element))
    }

    /// Guesses formats from file names before the drop, when the sandbox can't read the files yet.
    /// Names with no recognised extension count as `.other` (they can still be compressed).
    public static func predictedFormats(forFileNames names: [String]) -> [FileFormat] {
        names.map { name in
            FileFormat.fromExtension((name as NSString).pathExtension) ?? .other
        }
    }
}
