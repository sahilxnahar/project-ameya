import Foundation

// Privacy check, hidden-detail removal, photo details and checksums. These are "file tasks":
// they work on any kind of file, so they travel as `ConversionOptions.task` instead of a format
// change. The worker looks at the file's real contents (never trusting the name) and decides how
// to read or clean it. Reports leave the worker as small JSON files (target `.json`).

/// A job that isn't a format change.
public enum FileTask: Codable, Sendable, Equatable {
    /// Writes a `PrivacyReport` (JSON) about the hidden details in the file.
    case inspect
    /// Writes the same kind of file without its hidden details (author, location, device…).
    case clean
    /// Writes a copy of a photo with new details (date taken, title, author…).
    case editDetails(PhotoDetailsEdit)
    /// Writes a `ChecksumReport` (JSON). The file is read in chunks, so size doesn't matter.
    case checksum([ChecksumAlgorithm])
}

// MARK: Privacy report

/// What the privacy check found. Values are plain text copied out of the file, clipped and
/// cleaned of control characters by the worker, so they are safe to show.
public struct PrivacyReport: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case photo, pdf, office, epub, media, other

        public var title: String {
            switch self {
            case .photo: "Photo"
            case .pdf: "PDF"
            case .office: "Office document"
            case .epub: "E-book"
            case .media: "Sound or video"
            case .other: "File"
            }
        }
    }

    /// How findings are grouped, most personal first.
    public enum Group: String, Codable, Sendable, CaseIterable {
        case location, name, device, edits, other

        public var title: String {
            switch self {
            case .location: "Location"
            case .name: "Your name"
            case .device: "Device"
            case .edits: "Edits"
            case .other: "Other"
            }
        }

        /// Who could see this, in plain words.
        public var explanation: String {
            switch self {
            case .location: "Where this was made. Anyone you share it with could find this place."
            case .name: "Names of people who made or changed this file. Anyone you share it with can read them."
            case .device: "The camera, phone or computer used, sometimes with a serial number that can link your files together."
            case .edits: "The apps used and when the file was made or changed, which can show its history."
            case .other: "Other hidden notes, labels and attachments saved inside the file."
            }
        }

        public var systemImage: String {
            switch self {
            case .location: "location.fill"
            case .name: "person.fill"
            case .device: "camera.fill"
            case .edits: "clock.arrow.circlepath"
            case .other: "doc.text.magnifyingglass"
            }
        }
    }

    public struct Finding: Codable, Sendable, Equatable {
        public var group: Group
        /// "Author", "GPS position", "Camera serial number"…
        public var label: String
        public var value: String

        public init(group: Group, label: String, value: String) {
            self.group = group
            self.label = PrivacyReport.clip(label, limit: 80)
            self.value = PrivacyReport.clip(value)
        }
    }

    /// Facts batch rename can use. Not secrets in themselves.
    public struct Facts: Codable, Sendable, Equatable {
        public var width: Int?
        public var height: Int?
        /// EXIF style, "yyyy:MM:dd HH:mm:ss", in the camera's own clock.
        public var dateTaken: String?
        public var camera: String?

        public init(width: Int? = nil, height: Int? = nil, dateTaken: String? = nil, camera: String? = nil) {
            self.width = width
            self.height = height
            self.dateTaken = dateTaken
            self.camera = camera
        }
    }

    public var kind: Kind
    public var findings: [Finding]
    public var facts: Facts
    /// Whether "Remove these" can clean this file.
    public var canClean: Bool
    /// Things cleaning leaves in place (or why it can't run), in plain sentences.
    public var kept: [String]

    public init(kind: Kind, findings: [Finding] = [], facts: Facts = Facts(), canClean: Bool, kept: [String] = []) {
        self.kind = kind
        self.findings = Array(findings.prefix(Self.maxFindings))
        self.facts = facts
        self.canClean = canClean
        self.kept = kept
    }

    public static let maxFindings = 300
    /// Reports are small; anything bigger than this from the worker is refused.
    public static let maxJSONBytes = 2 << 20

    /// Findings by group, in `Group` order, leaving out empty groups.
    public var grouped: [(group: Group, findings: [Finding])] {
        Group.allCases.compactMap { group in
            let items = findings.filter { $0.group == group }
            return items.isEmpty ? nil : (group, items)
        }
    }

    /// One line of text, without control characters, at most `limit` characters.
    public static func clip(_ text: String, limit: Int = 300) -> String {
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.illegalCharacters.contains($0) ? " " : $0
        })).trimmingCharacters(in: .whitespaces)
        return cleaned.count > limit ? String(cleaned.prefix(limit - 1)) + "…" : cleaned
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> PrivacyReport {
        guard data.count <= maxJSONBytes else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(PrivacyReport.self, from: data)
    }
}

// MARK: Photo details

/// New details for a photo. `nil` keeps what's there; an empty string or list removes it.
public struct PhotoDetailsEdit: Codable, Sendable, Equatable {
    public enum DateChange: Codable, Sendable, Equatable {
        case keep
        /// EXIF style, "yyyy:MM:dd HH:mm:ss".
        case set(String)
        /// For a camera whose clock was wrong: moves every date by this many hours.
        case shift(hours: Double)
    }

    public var date: DateChange
    public var title: String?
    public var description: String?
    public var author: String?
    public var copyright: String?
    public var keywords: [String]?

    public init(date: DateChange = .keep, title: String? = nil, description: String? = nil,
                author: String? = nil, copyright: String? = nil, keywords: [String]? = nil) {
        self.date = date
        self.title = title
        self.description = description
        self.author = author
        self.copyright = copyright
        self.keywords = keywords
    }

    public var isEmpty: Bool { self == PhotoDetailsEdit() }
}

/// EXIF dates ("2024:05:01 14:30:00") have no time zone: they are whatever the camera clock said.
/// Arithmetic is done on that wall-clock time in UTC, so daylight-saving changes never add or lose an hour.
public enum ExifDate {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    /// The wall-clock time as a `Date` in UTC. Accepts "yyyy:MM:dd HH:mm:ss", with "-" or "T" too.
    public static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for format in ["yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy:MM:dd"] {
            if let date = formatter(format).date(from: String(trimmed.prefix(format.replacingOccurrences(of: "'", with: "").count))) {
                return date
            }
        }
        return nil
    }

    public static func string(from date: Date) -> String {
        formatter("yyyy:MM:dd HH:mm:ss").string(from: date)
    }

    /// `text` moved by `hours` (may be negative or fractional, e.g. 5.5). `nil` if it isn't a date.
    public static func shifted(_ text: String, byHours hours: Double) -> String? {
        guard let date = parse(text) else { return nil }
        return string(from: date.addingTimeInterval((hours * 3600).rounded()))
    }

    /// Formats a camera date with a user pattern such as "yyyy-MM-dd", for file names.
    public static func format(_ text: String, as pattern: String) -> String? {
        parse(text).map { formatter(pattern).string(from: $0) }
    }
}

// MARK: Checksums

public enum ChecksumAlgorithm: String, Codable, Sendable, CaseIterable {
    case sha256, sha1, md5

    public var title: String {
        switch self {
        case .sha256: "SHA-256"
        case .sha1: "SHA-1"
        case .md5: "MD5"
        }
    }

    /// Length of the digest written as hexadecimal.
    public var hexLength: Int {
        switch self {
        case .sha256: 64
        case .sha1: 40
        case .md5: 32
        }
    }
}

public struct ChecksumReport: Codable, Sendable, Equatable {
    public var bytes: Int64
    /// Lowercase hexadecimal, keyed by `ChecksumAlgorithm.rawValue` ("sha256", "sha1", "md5").
    public var digests: [String: String]

    public init(bytes: Int64, digests: [ChecksumAlgorithm: String]) {
        self.bytes = bytes
        self.digests = Dictionary(uniqueKeysWithValues: digests.map { ($0.key.rawValue, $0.value) })
    }

    public subscript(algorithm: ChecksumAlgorithm) -> String? { digests[algorithm.rawValue] }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    public static func decode(_ data: Data) throws -> ChecksumReport {
        guard data.count <= 64 << 10 else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(ChecksumReport.self, from: data)
    }
}

/// Compares a pasted checksum with a computed one.
public enum ChecksumMatch: Equatable, Sendable {
    case match(ChecksumAlgorithm)
    case different(ChecksumAlgorithm)
    /// Nothing that looks like a SHA-256, SHA-1 or MD5 checksum was pasted.
    case notAChecksum

    /// The hexadecimal checksum in what was pasted. Accepts "abc…", "ABC…", "SHA256 (file) = abc…",
    /// "abc…  file.dmg" and checksums split by spaces. Returns the algorithm its length implies.
    public static func expected(in pasted: String) -> (ChecksumAlgorithm, String)? {
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        let runs = pasted.unicodeScalars.split { !hex.contains($0) }.map { String(String.UnicodeScalarView($0)).lowercased() }
        let candidates = runs + [runs.joined()] // a checksum pasted in groups, e.g. "ab12 cd34 …"
        for algorithm in ChecksumAlgorithm.allCases {
            if let match = candidates.first(where: { $0.count == algorithm.hexLength }) { return (algorithm, match) }
        }
        return nil
    }

    public static func compare(pasted: String, with report: ChecksumReport) -> ChecksumMatch {
        guard let (algorithm, expected) = expected(in: pasted), let actual = report[algorithm] else {
            return .notAChecksum
        }
        return actual.lowercased() == expected ? .match(algorithm) : .different(algorithm)
    }

    /// Plain words for the result.
    public var message: String {
        switch self {
        case .match(let algorithm): "✓ Match. This file is exactly the one you expected (\(algorithm.title))."
        case .different(let algorithm): "✗ Different. This file isn't the one you expected (\(algorithm.title)). It may be damaged or changed: don't open it."
        case .notAChecksum: "That doesn't look like a SHA-256, SHA-1 or MD5 checksum. Paste the long string of letters and numbers from the website."
        }
    }
}
