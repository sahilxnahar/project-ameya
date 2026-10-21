import Foundation

/// Chooses where a converted file goes. Never picks a name that already exists,
/// so an original or an earlier result can never be overwritten.
public enum OutputPlanner {
    /// - Parameters:
    ///   - source: the file being converted.
    ///   - target: the output format.
    ///   - directory: where the output should be written.
    ///   - suffix: added after the name, e.g. "(rotated)" gives "photo (rotated).jpg".
    ///   - isTaken: whether a candidate URL is already used (on disk or reserved by a queued job).
    public static func destination(
        for source: URL,
        target: FileFormat,
        in directory: URL,
        suffix: String? = nil,
        isTaken: (URL) -> Bool
    ) -> URL {
        unique(base: name(of: source, suffix: suffix), extension: target.preferredExtension, in: directory, isTaken: isTaken)
    }

    /// Convenience that checks the file system.
    public static func destination(for source: URL, target: FileFormat, in directory: URL, suffix: String? = nil) -> URL {
        destination(for: source, target: target, in: directory, suffix: suffix) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// A new folder for a job that produces several files, e.g. "report (pages)".
    public static func folderDestination(
        for source: URL,
        suffix: String,
        in directory: URL,
        isTaken: (URL) -> Bool
    ) -> URL {
        unique(base: name(of: source, suffix: suffix), extension: nil, in: directory, isTaken: isTaken)
    }

    /// Convenience that checks the file system.
    public static func folderDestination(for source: URL, suffix: String, in directory: URL) -> URL {
        folderDestination(for: source, suffix: suffix, in: directory) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private static func name(of source: URL, suffix: String?) -> String {
        let base = baseName(of: source)
        guard let suffix = suffix?.trimmingCharacters(in: .whitespaces), !suffix.isEmpty else { return base }
        return "\(base) \(suffix.replacingOccurrences(of: "/", with: "-"))"
    }

    private static func unique(base: String, extension ext: String?, in directory: URL, isTaken: (URL) -> Bool) -> URL {
        func candidate(_ name: String) -> URL {
            ext.map { directory.appendingPathComponent("\(name).\($0)") }
                ?? directory.appendingPathComponent(name, isDirectory: true)
        }
        var result = candidate(base)
        var counter = 2
        while isTaken(result) {
            result = candidate("\(base) \(counter)")
            counter += 1
        }
        return result
    }

    /// The file name without its extension. Hidden files keep their leading dot stripped,
    /// so outputs are always visible in Finder.
    static func baseName(of url: URL) -> String {
        var trimmed = url.deletingPathExtension()
        // Compound archive extensions: "photos.tar.gz" → "photos".
        if trimmed.pathExtension.lowercased() == "tar" { trimmed = trimmed.deletingPathExtension() }
        var name = trimmed.lastPathComponent
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "Converted" : name
    }
}
