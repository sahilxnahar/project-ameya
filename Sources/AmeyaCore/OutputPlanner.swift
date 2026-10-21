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
        let (stem, ext) = nameParts(for: source, target: target)
        let base = suffixed(stem, suffix)
        func name(_ suffix: String) -> String { ext.isEmpty ? base + suffix : "\(base)\(suffix).\(ext)" }
        var candidate = directory.appendingPathComponent(name(""))
        var counter = 2
        while isTaken(candidate) {
            candidate = directory.appendingPathComponent(name(" \(counter)"))
            counter += 1
        }
        return candidate
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
        suffixed(baseName(of: source), suffix)
    }

    private static func suffixed(_ base: String, _ suffix: String?) -> String {
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

    /// The name stem and extension for an output. Compressing keeps the whole original name
    /// ("report.pdf" → "report.pdf.gz"); decompressing gives it back ("report.pdf.gz" → "report.pdf"),
    /// falling back to the name stored in a gzip header when the file name has no inner extension.
    static func nameParts(for source: URL, target: FileFormat) -> (base: String, ext: String) {
        if target.isCompression {
            var name = source.lastPathComponent
            while name.hasPrefix(".") { name.removeFirst() }
            let inner = (name as NSString).pathExtension
            let stem = inner.isEmpty ? name : (name as NSString).deletingPathExtension
            guard !stem.isEmpty else { return ("Converted", target.preferredExtension) }
            return (stem, inner.isEmpty ? target.preferredExtension : "\(inner).\(target.preferredExtension)")
        }
        if target == .decompressed {
            var inner = source.lastPathComponent
            if ["gz", "gzip", "bz2", "xz"].contains(source.pathExtension.lowercased()) {
                inner = source.deletingPathExtension().lastPathComponent
            }
            if (inner as NSString).pathExtension.isEmpty, let handle = try? FileHandle(forReadingFrom: source) {
                let header = (try? handle.read(upToCount: 4096)) ?? Data()
                try? handle.close()
                if let original = FileFormat.gzipOriginalName(header) { inner = original }
            }
            while inner.hasPrefix(".") { inner.removeFirst() }
            let ext = (inner as NSString).pathExtension
            let stem = ext.isEmpty ? inner : (inner as NSString).deletingPathExtension
            return stem.isEmpty ? ("Decompressed", ext) : (stem, ext)
        }
        if target == .other {
            // "The same kind of file": tools that keep a format Ameya doesn't name (e.g. cleaning an XLSX).
            return (baseName(of: source), source.pathExtension)
        }
        return (baseName(of: source), target.preferredExtension)
    }
}
