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
public enum WheelModifier: String, CaseIterable, Sendable, Codable {
    case shift, command, control, option

    public var symbol: String {
        switch self {
        case .shift: "⇧"
        case .command: "⌘"
        case .control: "⌃"
        case .option: "⌥"
        }
    }

    public var title: String {
        switch self {
        case .shift: "Shift"
        case .command: "Command"
        case .control: "Control"
        case .option: "Option"
        }
    }
}

/// Which key opens which wheel. Each key opens at most one wheel; a wheel may have no key.
public struct WheelModifierMapping: Sendable, Equatable, Codable {
    public private(set) var keys: [WheelRing: WheelModifier]

    public static let standard = WheelModifierMapping(keys: [.convert: .shift, .tools: .command, .actions: .control])

    public init(keys: [WheelRing: WheelModifier]) {
        // Drop duplicates, keeping the first ring (in display order) that claimed a key.
        var used: Set<WheelModifier> = []
        var clean: [WheelRing: WheelModifier] = [:]
        for ring in WheelRing.allCases {
            if let key = keys[ring], used.insert(key).inserted { clean[ring] = key }
        }
        self.keys = clean
    }

    public func key(for ring: WheelRing) -> WheelModifier? { keys[ring] }

    /// Gives `ring` the key `modifier`. If another wheel had that key, the two wheels swap keys,
    /// so a choice in Settings never silently disables another wheel.
    public func assigning(_ modifier: WheelModifier?, to ring: WheelRing) -> WheelModifierMapping {
        var keys = self.keys
        let previous = keys[ring]
        if let modifier, let other = keys.first(where: { $0.value == modifier && $0.key != ring })?.key {
            keys[other] = previous
        }
        keys[ring] = modifier
        return WheelModifierMapping(keys: keys)
    }

    /// The wheel for the keys currently held, or `nil` if none of them opens a wheel.
    /// When several are held, the first wheel in display order wins (Convert, Tools, Actions).
    public func ring(for held: Set<WheelModifier>) -> WheelRing? {
        WheelRing.allCases.first { ring in keys[ring].map(held.contains) ?? false }
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

/// Everything the wheel reads from Settings, with the UserDefaults keys it is stored under.
public struct WheelSettings: Sendable, Equatable {
    public static let enabledKey = "wheel.enabled"
    public static let sizeKey = "wheel.size"
    public static let excludedKey = "wheel.excludedApps"
    public static func keyKey(_ ring: WheelRing) -> String { "wheel.key.\(ring.rawValue)" }
    /// Stored for a wheel deliberately set to "No key".
    public static let noKey = "none"

    public var isEnabled: Bool
    public var mapping: WheelModifierMapping
    public var size: WheelSize
    public var exclusions: WheelExclusions

    public init(isEnabled: Bool = true, mapping: WheelModifierMapping = .standard,
                size: WheelSize = .medium, exclusions: WheelExclusions = WheelExclusions()) {
        self.isEnabled = isEnabled
        self.mapping = mapping
        self.size = size
        self.exclusions = exclusions
    }

    /// Reads settings, falling back to the defaults (wheel on, ⇧ ⌘ ⌃, medium) for anything unset.
    public static func load(from defaults: UserDefaults) -> WheelSettings {
        var keys: [WheelRing: WheelModifier] = [:]
        for ring in WheelRing.allCases {
            switch defaults.string(forKey: keyKey(ring)) {
            case nil: keys[ring] = WheelModifierMapping.standard.key(for: ring)
            case noKey?: break
            case let raw?: keys[ring] = WheelModifier(rawValue: raw)
            }
        }
        return WheelSettings(
            isEnabled: defaults.object(forKey: enabledKey) as? Bool ?? true,
            mapping: WheelModifierMapping(keys: keys),
            size: defaults.string(forKey: sizeKey).flatMap(WheelSize.init(rawValue:)) ?? .medium,
            exclusions: WheelExclusions(defaults.stringArray(forKey: excludedKey) ?? [])
        )
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(isEnabled, forKey: Self.enabledKey)
        defaults.set(size.rawValue, forKey: Self.sizeKey)
        defaults.set(exclusions.bundleIDs, forKey: Self.excludedKey)
        for ring in WheelRing.allCases {
            defaults.set(mapping.key(for: ring)?.rawValue ?? Self.noKey, forKey: Self.keyKey(ring))
        }
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
