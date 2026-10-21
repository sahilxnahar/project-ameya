import Foundation

/// How batch rename builds new names: a pattern, then find/replace, then a case change.
public struct RenameRule: Equatable, Sendable {
    public enum CaseChange: String, CaseIterable, Sendable {
        case keep, lower, upper, title

        public var title: String {
            switch self {
            case .keep: "Keep as typed"
            case .lower: "lowercase"
            case .upper: "UPPERCASE"
            case .title: "Title Case"
            }
        }
    }

    /// Tokens: {name}, {n} or {n:3} (a counter, padded to 3 digits), {date taken} or
    /// {date taken:yyyy-MM-dd}, {date modified} (same formats), {width}, {height}, {camera}, {ext}.
    public var pattern: String
    public var find: String
    public var replace: String
    public var caseChange: CaseChange
    public var startNumber: Int

    public init(pattern: String = "{name}", find: String = "", replace: String = "",
                caseChange: CaseChange = .keep, startNumber: Int = 1) {
        self.pattern = pattern
        self.find = find
        self.replace = replace
        self.caseChange = caseChange
        self.startNumber = startNumber
    }
}

/// One file to rename.
public struct RenameItem: Equatable, Sendable {
    /// The current file name, with extension.
    public var name: String
    public var dateModified: Date?
    /// From the privacy check (read in the worker); only needed for photo tokens.
    public var facts: PrivacyReport.Facts?

    public init(name: String, dateModified: Date? = nil, facts: PrivacyReport.Facts? = nil) {
        self.name = name
        self.dateModified = dateModified
        self.facts = facts
    }
}

public enum RenamePlanner {
    public static let defaultDateFormat = "yyyy-MM-dd"
    static let maxStemLength = 200

    /// Whether the pattern uses details that have to be read from inside the files.
    public static func needsFacts(_ pattern: String) -> Bool {
        tokens(in: pattern).contains { ["date taken", "width", "height", "camera"].contains($0.name) }
    }

    /// New names, in order, all different from each other (ignoring case, as macOS disks do) and
    /// from every name `isTaken` reports. A clash gets " 2", " 3"… — nothing is ever overwritten.
    public static func newNames(for items: [RenameItem], rule: RenameRule,
                                timeZone: TimeZone = .current, isTaken: (String) -> Bool = { _ in false }) -> [String] {
        var used: Set<String> = []
        return items.enumerated().map { index, item in
            let (stem, ext) = split(item.name)
            var base = expand(rule.pattern, item: item, number: rule.startNumber + index, timeZone: timeZone)
            if !rule.find.isEmpty {
                base = base.replacingOccurrences(of: rule.find, with: rule.replace, options: .caseInsensitive)
            }
            base = sanitize(changeCase(base, rule.caseChange))
            if base.isEmpty { base = sanitize(stem).isEmpty ? "Untitled" : sanitize(stem) }
            func full(_ stem: String) -> String { ext.isEmpty ? stem : "\(stem).\(ext)" }
            var candidate = full(base)
            var counter = 2
            while used.contains(candidate.lowercased()) || isTaken(candidate) {
                candidate = full("\(base) \(counter)")
                counter += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }

    /// Fills in the tokens of `pattern` for one file. Unknown tokens are left as typed.
    public static func expand(_ pattern: String, item: RenameItem, number: Int, timeZone: TimeZone = .current) -> String {
        let (stem, ext) = split(item.name)
        var result = ""
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            let token = Token(String(rest[rest.index(after: open)..<close]))
            result += value(of: token, item: item, stem: stem, ext: ext, number: number, timeZone: timeZone)
                ?? String(rest[open...close])
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
    }

    struct Token {
        var name: String
        var argument: String?

        init(_ text: String) {
            let parts = text.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            name = parts.first?.lowercased() ?? ""
            argument = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        }
    }

    static func tokens(in pattern: String) -> [Token] {
        var found: [Token] = []
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            found.append(Token(String(rest[rest.index(after: open)..<close])))
            rest = rest[rest.index(after: close)...]
        }
        return found
    }

    private static func value(of token: Token, item: RenameItem, stem: String, ext: String,
                              number: Int, timeZone: TimeZone) -> String? {
        switch token.name {
        case "name": return stem
        case "ext": return ext
        case "n":
            let digits = min(max(Int(token.argument ?? "") ?? 1, 1), 9)
            let text = String(abs(number))
            return (number < 0 ? "-" : "") + String(repeating: "0", count: max(0, digits - text.count)) + text
        case "date taken":
            guard let taken = item.facts?.dateTaken else { return "" }
            return ExifDate.format(taken, as: token.argument ?? defaultDateFormat) ?? ""
        case "date modified":
            guard let date = item.dateModified else { return "" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = token.argument ?? defaultDateFormat
            return formatter.string(from: date)
        case "width": return item.facts?.width.map(String.init) ?? ""
        case "height": return item.facts?.height.map(String.init) ?? ""
        case "camera": return item.facts?.camera ?? ""
        default: return nil
        }
    }

    static func changeCase(_ text: String, _ change: RenameRule.CaseChange) -> String {
        switch change {
        case .keep: text
        case .lower: text.lowercased()
        case .upper: text.uppercased()
        case .title: text.capitalized
        }
    }

    /// A name macOS and Finder accept: no slashes, colons or control characters, no leading dot.
    static func sanitize(_ text: String) -> String {
        var cleaned = String(String.UnicodeScalarView(text.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if scalar == "/" || scalar == ":" { return "-" }
            return CharacterSet.controlCharacters.contains(scalar) ? nil : scalar
        }))
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > maxStemLength { cleaned = String(cleaned.prefix(maxStemLength)) }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    /// "photo.final.JPG" → ("photo.final", "JPG"). Hidden-file names like ".env" have no extension.
    static func split(_ name: String) -> (stem: String, ext: String) {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? (name, "") : (stem, ext)
    }
}
