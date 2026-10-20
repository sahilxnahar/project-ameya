import Foundation

/// Chooses where a converted file goes. Never picks a name that already exists,
/// so an original or an earlier result can never be overwritten.
public enum OutputPlanner {
    /// - Parameters:
    ///   - source: the file being converted.
    ///   - target: the output format.
    ///   - directory: where the output should be written.
    ///   - isTaken: whether a candidate URL is already used (on disk or reserved by a queued job).
    public static func destination(
        for source: URL,
        target: FileFormat,
        in directory: URL,
        isTaken: (URL) -> Bool
    ) -> URL {
        let base = baseName(of: source)
        let ext = target.preferredExtension
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while isTaken(candidate) {
            candidate = directory.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// Convenience that checks the file system.
    public static func destination(for source: URL, target: FileFormat, in directory: URL) -> URL {
        destination(for: source, target: target, in: directory) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// The file name without its extension. Hidden files keep their leading dot stripped,
    /// so outputs are always visible in Finder.
    static func baseName(of url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "Converted" : name
    }
}
