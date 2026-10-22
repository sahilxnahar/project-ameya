import Foundation

/// The type a setting must have to be exported or imported.
public enum SettingKind: Sendable, Equatable {
    case bool, string, double, stringArray
}

/// Settings as a small JSON file the user saves and opens themselves (Settings → Export/Import).
///
///     {"format": "ameya-settings", "version": 1, "settings": {"wheel.size": "large", …}}
///
/// Only keys the app lists in its schema travel, each checked against its kind, so a file can't
/// set anything else in the app's preferences. Schema keys ending in "*" match by prefix
/// ("hotkey.*" covers "hotkey.openPanel"). Nothing here touches the network.
public enum SettingsArchive {
    public static let format = "ameya-settings"
    public static let version = 1
    /// Larger files aren't settings.
    public static let maxBytes = 256 * 1024

    public enum Problem: Error, Equatable, LocalizedError {
        case notASettingsFile
        case newerVersion(Int)
        case tooLarge

        public var errorDescription: String? {
            switch self {
            case .notASettingsFile: "This file isn't an Ameya settings file."
            case let .newerVersion(version): "These settings come from a newer Ameya (version \(version)). Update Ameya to use them."
            case .tooLarge: "This file is too large to be Ameya settings."
            }
        }
    }

    /// The kind for `key`, or nil when the schema doesn't allow it.
    public static func kind(of key: String, in schema: [String: SettingKind]) -> SettingKind? {
        if let exact = schema[key] { return exact }
        return schema.first { pattern, _ in pattern.hasSuffix("*") && key.hasPrefix(String(pattern.dropLast())) }?.value
    }

    /// Keeps only allowed keys whose values have the right kind.
    public static func filter(_ values: [String: Any], schema: [String: SettingKind]) -> (kept: [String: Any], ignored: [String]) {
        var kept: [String: Any] = [:]
        var ignored: [String] = []
        for (key, value) in values {
            guard let kind = kind(of: key, in: schema), let clean = coerce(value, to: kind) else {
                ignored.append(key)
                continue
            }
            kept[key] = clean
        }
        return (kept, ignored.sorted())
    }

    /// JSON for `values` (from UserDefaults), sorted and readable.
    public static func export(_ values: [String: Any], schema: [String: SettingKind]) throws -> Data {
        let archive: [String: Any] = ["format": format, "version": version, "settings": filter(values, schema: schema).kept]
        return try JSONSerialization.data(withJSONObject: archive, options: [.prettyPrinted, .sortedKeys])
    }

    /// Reads a settings file: the values to apply, and the keys that were left out.
    public static func read(_ data: Data, schema: [String: SettingKind]) throws -> (values: [String: Any], ignored: [String]) {
        guard data.count <= maxBytes else { throw Problem.tooLarge }
        guard let archive = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              archive["format"] as? String == format,
              let settings = archive["settings"] as? [String: Any] else { throw Problem.notASettingsFile }
        let fileVersion = archive["version"] as? Int ?? 0
        guard fileVersion <= version else { throw Problem.newerVersion(fileVersion) }
        let result = filter(settings, schema: schema)
        return (result.kept, result.ignored)
    }

    private static func coerce(_ value: Any, to kind: SettingKind) -> Any? {
        switch kind {
        case .bool:
            // JSON numbers and booleans both arrive as NSNumber; only real booleans count.
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        case .string:
            guard let text = value as? String, text.count <= 4096 else { return nil }
            return text
        case .double:
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        case .stringArray:
            guard let list = value as? [Any], list.count <= 500 else { return nil }
            let texts = list.compactMap { $0 as? String }.filter { $0.count <= 4096 }
            return texts.count == list.count ? texts : nil
        }
    }
}
