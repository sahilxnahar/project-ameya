import Foundation

/// What people want a file to become, in plain words. Used to group "Convert to" choices.
public enum FormatKind: String, CaseIterable, Sendable, Identifiable {
    case photos, documents, audio, video, subtitles, data, contacts, maps, models, archives, compressed

    public var id: String { rawValue }

    public init(_ family: FileFormat.Family) {
        switch family {
        case .image: self = .photos
        case .document: self = .documents
        case .audio: self = .audio
        case .video: self = .video
        case .subtitle: self = .subtitles
        case .data: self = .data
        case .contacts: self = .contacts
        case .geo: self = .maps
        case .model: self = .models
        case .archive: self = .archives
        case .compressed: self = .compressed
        }
    }

    public var title: String {
        switch self {
        case .photos: "Photos"
        case .documents: "Documents"
        case .audio: "Audio"
        case .video: "Video"
        case .subtitles: "Subtitles"
        case .data: "Spreadsheets & data"
        case .contacts: "Contacts"
        case .maps: "Maps & routes"
        case .models: "3D"
        case .archives: "Archives"
        case .compressed: "Compressed files"
        }
    }

    /// SF Symbol, one per kind, used everywhere a kind is shown.
    public var systemImage: String {
        switch self {
        case .photos: "photo"
        case .documents: "doc.text"
        case .audio: "waveform"
        case .video: "film"
        case .subtitles: "captions.bubble"
        case .data: "tablecells"
        case .contacts: "person.crop.circle"
        case .maps: "map"
        case .models: "cube"
        case .archives: "archivebox"
        case .compressed: "doc.zipper"
        }
    }

    /// Kinds people most often want next, after the source's own kind.
    var affinity: [FormatKind] {
        switch self {
        case .video: [.video, .audio, .photos, .subtitles, .documents]
        case .audio: [.audio, .documents, .subtitles, .video]
        case .photos: [.photos, .documents]
        case .documents: [.documents, .photos, .audio]
        case .subtitles: [.subtitles, .documents]
        default: [self]
        }
    }
}

/// A titled set of formats, most likely first.
public struct FormatGroup: Identifiable, Equatable, Sendable {
    public let kind: FormatKind
    public var formats: [FileFormat]
    public var id: FormatKind { kind }

    public init(kind: FormatKind, formats: [FileFormat]) {
        self.kind = kind
        self.formats = formats
    }
}

/// "Convert to" choices: the likely ones up front, everything else behind "More formats".
public struct FormatChoices: Equatable, Sendable {
    public let main: [FormatGroup]
    public let more: [FormatGroup]

    public var isEmpty: Bool { main.isEmpty && more.isEmpty }
    public var all: [FileFormat] { (main + more).flatMap(\.formats) }

    /// - Parameters:
    ///   - targets: what every pending file can become.
    ///   - sources: the pending files' formats, to put the matching kind first.
    ///   - perGroup: how many choices each group shows before "More formats".
    ///   - showAllUpTo: with this many targets or fewer, nothing is tucked away.
    public init(targets: [FileFormat], sources: [FileFormat], perGroup: Int = 4, showAllUpTo: Int = 8) {
        var order: [FormatKind] = []
        for source in sources {
            for kind in FormatKind(source.family).affinity where !order.contains(kind) { order.append(kind) }
        }
        for kind in FormatKind.allCases where !order.contains(kind) { order.append(kind) }

        let byKind = Dictionary(grouping: targets, by: { FormatKind($0.family) })
        let groups = order.compactMap { kind -> FormatGroup? in
            guard let formats = byKind[kind], !formats.isEmpty else { return nil }
            return FormatGroup(kind: kind, formats: formats.sorted(by: FormatRank.isMoreLikely))
        }
        if targets.count <= showAllUpTo {
            main = groups
            more = []
            return
        }
        var main: [FormatGroup] = []
        var more: [FormatGroup] = []
        for (index, group) in groups.enumerated() {
            // The source's own kind gets the most room; others show their top picks.
            let limit = index == 0 ? perGroup + 2 : perGroup
            let likely = group.formats.filter { FormatRank.isCommon($0) }
            let shown = Array(likely.prefix(limit))
            if !shown.isEmpty { main.append(FormatGroup(kind: group.kind, formats: shown)) }
            let rest = group.formats.filter { !shown.contains($0) }
            if !rest.isEmpty { more.append(FormatGroup(kind: group.kind, formats: rest)) }
        }
        if main.isEmpty { main = more; more = [] }
        self.main = main
        self.more = more
    }
}

/// How likely someone is to want each format. Lower comes first.
public enum FormatRank {
    static let order: [FileFormat] = [
        .jpeg, .png, .pdf, .heic, .webp, .gif, .tiff, .avif,
        .docx, .txt, .md, .html, .rtf, .epub, .odt,
        .mp3, .m4a, .wav, .flac, .aiff, .alac, .ogg, .opus,
        .mp4, .mov, .m4v, .webm, .mkv, .avi,
        .srt, .vtt,
        .csv, .xlsx, .json, .tsv, .yaml, .xml, .plist, .sql, .sqlite,
        .vcf, .gpx, .kml, .geojson, .kmz,
        .usdz, .obj, .stl,
        .zip, .tgz, .sevenZip, .tar,
    ]
    private static let rank: [FileFormat: Int] = Dictionary(
        uniqueKeysWithValues: order.enumerated().map { ($1, $0) })

    public static func rank(_ format: FileFormat) -> Int {
        rank[format] ?? (order.count + (FileFormat.allCases.firstIndex(of: format) ?? 0))
    }

    /// Formats in the popularity list; the rest are for people who know they need them.
    public static func isCommon(_ format: FileFormat) -> Bool { rank[format] != nil }

    public static func isMoreLikely(_ a: FileFormat, _ b: FileFormat) -> Bool { rank(a) < rank(b) }
}

/// "Type to find a format": matches names, file extensions and everyday words.
public enum FormatSearch {
    static let aliases: [FileFormat: [String]] = [
        .jpeg: ["jpg", "photo", "picture"],
        .png: ["picture", "screenshot", "transparent"],
        .heic: ["iphone", "heif"],
        .gif: ["animation", "animated"],
        .pdf: ["acrobat", "print"],
        .docx: ["word"],
        .doc: ["word"],
        .xlsx: ["excel", "spreadsheet"],
        .csv: ["spreadsheet", "excel", "table"],
        .txt: ["text", "plain"],
        .md: ["markdown"],
        .mp3: ["music", "song"],
        .m4a: ["aac", "music", "itunes"],
        .wav: ["wave"],
        .mp4: ["movie", "h264", "youtube"],
        .mov: ["quicktime", "movie"],
        .srt: ["subtitles", "captions"],
        .vtt: ["subtitles", "captions"],
        .epub: ["book", "ebook"],
        .vcf: ["contact", "card"],
        .zip: ["archive"],
        .usdz: ["ar", "augmented"],
    ]

    /// The formats matching `query`, keeping their order. An empty query matches everything.
    public static func filter(_ formats: [FileFormat], query: String) -> [FileFormat] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return formats }
        return formats.filter { matches($0, needle) }
    }

    public static func matches(_ format: FileFormat, query: String) -> Bool {
        let needle = normalized(query)
        return needle.isEmpty || matches(format, needle)
    }

    private static func matches(_ format: FileFormat, _ needle: String) -> Bool {
        if format.displayName.lowercased().contains(needle) { return true }
        let words = [format.rawValue] + format.extensions + (aliases[format] ?? [])
            + FormatKind(format.family).title.lowercased().split(separator: " ").map(String.init)
        return words.contains { $0.lowercased().hasPrefix(needle) }
    }

    private static func normalized(_ query: String) -> String {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while text.hasPrefix(".") { text.removeFirst() }
        return text
    }
}
