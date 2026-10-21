import Foundation

/// One watched folder and what to do with new files that arrive in it.
///
/// Only files that arrive while Ameya runs are touched. Originals are only ever read, or moved
/// to the Trash (recoverable) when the user picks that.
public struct WatchRule: Codable, Sendable, Equatable, Identifiable {
    public enum Folder: Codable, Sendable, Equatable {
        /// The real Downloads folder, which the sandbox grants by entitlement.
        case downloads
        /// A folder picked in an open panel, remembered as an app-scoped security-scoped bookmark.
        case picked(bookmark: Data, name: String)

        public var name: String {
            switch self {
            case .downloads: "Downloads"
            case let .picked(_, name): name
            }
        }
    }

    public enum Action: Codable, Sendable, Equatable {
        case convert(FileFormat)
        case recipe(UUID)
    }

    public enum Output: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Inside the watched folder, beside the original.
        case nextToOriginals
        /// Wherever Settings says converted files go.
        case ameyaFolder
        public var id: String { rawValue }
    }

    public enum Original: String, Codable, Sendable, CaseIterable, Identifiable {
        case keep
        case trash
        public var id: String { rawValue }
    }

    public var id: UUID
    public var isEnabled: Bool
    public var folder: Folder
    /// File types the rule applies to; anything else in the folder is left alone.
    public var fileTypes: [FileFormat]
    public var action: Action
    public var output: Output
    public var original: Original

    public init(id: UUID = UUID(), isEnabled: Bool = false, folder: Folder, fileTypes: [FileFormat],
                action: Action, output: Output = .nextToOriginals, original: Original = .keep) {
        self.id = id
        self.isEnabled = isEnabled
        self.folder = folder
        self.fileTypes = fileTypes
        self.action = action
        self.output = output
        self.original = original
    }

    /// Whether a file of this format (as detected from its contents) is one the rule handles.
    public func applies(to format: FileFormat) -> Bool {
        guard fileTypes.contains(format) else { return false }
        if case let .convert(target) = action { return target != format }
        return true
    }

    /// File name extensions worth watching (`StabilityTracker` waits for these to settle).
    public var extensions: Set<String> {
        Set(fileTypes.flatMap(\.extensions).map { $0.lowercased() })
    }

    /// A tracker for this rule's folder: waits until new files stop growing.
    public func makeTracker(stableFor: TimeInterval = 2) -> StabilityTracker {
        StabilityTracker(stableFor: stableFor, extensions: extensions)
    }
}

/// Saving, loading and migrating the list of watch rules.
public enum WatchRules {
    public static let storageKey = "watchRules"
    public static let pausedKey = "watchFoldersPaused"
    /// The settings the Downloads HEIC → JPEG auto-converter used before watch folders existed.
    public static let legacyEnabledKey = "autoConvertHEIC"
    public static let legacyOriginalKey = "heicOriginal"

    public static let downloadsHEICRuleID = UUID(uuidString: "0A7C0F01-4EA1-4C3B-9F00-D0A1E1C0DE01")!

    /// iPhone photos arriving in Downloads become JPEGs beside them. Off unless the old setting was on.
    public static func downloadsHEICRule(enabled: Bool = false, original: WatchRule.Original = .keep) -> WatchRule {
        WatchRule(id: downloadsHEICRuleID, isEnabled: enabled, folder: .downloads, fileTypes: [.heic],
                  action: .convert(.jpeg), output: .nextToOriginals, original: original)
    }

    /// The saved rules. The first time (nothing saved yet) the old HEIC setting becomes a
    /// Downloads rule that keeps whatever the user had chosen; unreadable data does the same.
    public static func load(saved: Data?, legacyEnabled: Bool, legacyOriginal: String?) -> [WatchRule] {
        if let saved, let rules = try? JSONDecoder().decode([WatchRule].self, from: saved) {
            return rules
        }
        let original = WatchRule.Original(rawValue: legacyOriginal ?? "") ?? .keep
        return [downloadsHEICRule(enabled: legacyEnabled, original: original)]
    }

    public static func load(from defaults: UserDefaults) -> [WatchRule] {
        load(saved: defaults.data(forKey: storageKey),
             legacyEnabled: defaults.bool(forKey: legacyEnabledKey),
             legacyOriginal: defaults.string(forKey: legacyOriginalKey))
    }

    public static func save(_ rules: [WatchRule], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: storageKey) }
    }

    /// The rules for one folder that handle a file of `format`, in list order.
    public static func matching(_ rules: [WatchRule], format: FileFormat) -> [WatchRule] {
        rules.filter { $0.isEnabled && $0.applies(to: format) }
    }
}
