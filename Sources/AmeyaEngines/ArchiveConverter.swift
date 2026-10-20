import AmeyaCore
import CArchive
import Foundation

/// Repacks archives between ZIP, TAR, TAR.GZ, TAR.BZ2, TAR.XZ and 7-Zip (RAR is read-only),
/// streaming entry by entry through the system libarchive. Nothing is extracted to disk.
///
/// Safety: entries with absolute or `..` paths are left out, links that point outside the
/// archive and device files are dropped, and total size, entry count and compression ratio
/// are capped so a small "zip bomb" can't fill the disk.
enum ArchiveConverter {
    struct Limits {
        var maxEntries = 100_000
        var maxTotalBytes: Int64 = 16 << 30 // 16 GiB uncompressed
        var maxRatio: Int64 = 250 // uncompressed ÷ compressed, checked once past 1 GiB
    }

    static func repack(input: URL, to target: FileFormat, output: URL, limits: Limits = Limits(), progress: (Double) -> Void) throws -> [ConversionNote] {
        guard let reader = archive_read_new() else { throw ConversionError.mediaFailed("libarchive unavailable") }
        defer { archive_read_free(reader) }
        archive_read_support_filter_all(reader)
        archive_read_support_format_all(reader)
        guard archive_read_open_filename(reader, input.path, 64 * 1024) == ARCHIVE_OK else {
            throw ConversionError.unreadable
        }

        guard let writer = archive_write_new() else { throw ConversionError.mediaFailed("libarchive unavailable") }
        defer { archive_write_free(writer) }
        try configure(writer, for: target)
        guard archive_write_open_filename(writer, output.path) == ARCHIVE_OK else {
            throw ConversionError.encodeFailed(target)
        }

        let compressedSize = Int64((try? FileManager.default.attributesOfItem(atPath: input.path)[.size] as? Int) ?? 1)
        var notes: Set<ConversionNote> = []
        var entries = 0
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var entry: OpaquePointer?

        while true {
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status >= ARCHIVE_WARN, let entry else {
                throw ConversionError.mediaFailed(errorMessage(reader) ?? "the archive is damaged")
            }
            if archive_entry_is_encrypted(entry) != 0 {
                throw ConversionError.mediaFailed("password-protected archives aren't supported yet")
            }
            entries += 1
            guard entries <= limits.maxEntries else {
                throw ConversionError.mediaFailed("the archive has more than \(limits.maxEntries) entries")
            }

            guard let rawPath = string(archive_entry_pathname_utf8(entry)) ?? string(archive_entry_pathname(entry)),
                  let path = safePath(rawPath) else {
                notes.insert(.unsafeEntriesSkipped)
                continue
            }

            let type = archive_entry_filetype(entry) & mode_t(AE_IFMT)
            if type == mode_t(AE_IFLNK) {
                guard let target = string(archive_entry_symlink(entry)), linkStaysInside(target, from: path) else {
                    notes.insert(.specialFilesSkipped)
                    continue
                }
            } else if type != mode_t(AE_IFREG) && type != mode_t(AE_IFDIR) {
                notes.insert(.specialFilesSkipped)
                continue
            }

            guard let copy = archive_entry_clone(entry) else { throw ConversionError.mediaFailed("out of memory") }
            defer { archive_entry_free(copy) }
            archive_entry_set_pathname_utf8(copy, path)
            if let hardlink = string(archive_entry_hardlink(entry)) {
                guard let safeLink = safePath(hardlink) else {
                    notes.insert(.unsafeEntriesSkipped)
                    continue
                }
                archive_entry_set_hardlink_utf8(copy, safeLink)
            }
            guard archive_write_header(writer, copy) >= ARCHIVE_WARN else {
                throw ConversionError.mediaFailed(errorMessage(writer) ?? "couldn't write an entry")
            }

            if type == mode_t(AE_IFREG) {
                while true {
                    let read = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                    if read == 0 { break }
                    guard read > 0 else {
                        throw ConversionError.mediaFailed(errorMessage(reader) ?? "the archive is damaged")
                    }
                    total += Int64(read)
                    guard total <= limits.maxTotalBytes else {
                        throw ConversionError.mediaFailed("the archive unpacks to more than \(limits.maxTotalBytes >> 30) GB")
                    }
                    if total > 1 << 30 && total / max(compressedSize, 1) > limits.maxRatio {
                        throw ConversionError.mediaFailed("the archive expands suspiciously (possible zip bomb)")
                    }
                    let written = buffer.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, read) }
                    guard written == read else {
                        throw ConversionError.mediaFailed(errorMessage(writer) ?? "couldn't write data")
                    }
                }
            }
            progress(min(0.99, Double(archive_filter_bytes(reader, -1)) / Double(max(compressedSize, 1))))
        }

        guard archive_write_close(writer) == ARCHIVE_OK else {
            throw ConversionError.mediaFailed(errorMessage(writer) ?? "couldn't finish the archive")
        }
        progress(1)
        return notes.sorted { $0.rawValue < $1.rawValue }
    }

    private static func configure(_ writer: OpaquePointer, for target: FileFormat) throws {
        let ok: Bool
        switch target {
        case .zip:
            ok = archive_write_set_format_zip(writer) == ARCHIVE_OK
        case .sevenZip:
            ok = archive_write_set_format_7zip(writer) == ARCHIVE_OK
        case .tar:
            ok = archive_write_set_format_pax_restricted(writer) == ARCHIVE_OK
        case .tgz:
            ok = archive_write_set_format_pax_restricted(writer) == ARCHIVE_OK && archive_write_add_filter_gzip(writer) == ARCHIVE_OK
        case .tbz2:
            ok = archive_write_set_format_pax_restricted(writer) == ARCHIVE_OK && archive_write_add_filter_bzip2(writer) == ARCHIVE_OK
        case .txz:
            ok = archive_write_set_format_pax_restricted(writer) == ARCHIVE_OK && archive_write_add_filter_xz(writer) == ARCHIVE_OK
        default:
            ok = false
        }
        guard ok else { throw ConversionError.unsupportedTarget(target) }
    }

    /// A relative path with no empty, `.` or `..` components, or nil if the entry must be skipped.
    static func safePath(_ raw: String) -> String? {
        let isDirectory = raw.hasSuffix("/")
        var components: [Substring] = []
        for component in raw.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { return nil }
            components.append(component)
        }
        // Absolute paths are rejected rather than silently made relative.
        guard !components.isEmpty, !raw.hasPrefix("/") else { return nil }
        return components.joined(separator: "/") + (isDirectory ? "/" : "")
    }

    /// Whether a symbolic link target resolves to somewhere inside the archive.
    static func linkStaysInside(_ target: String, from entryPath: String) -> Bool {
        guard !target.hasPrefix("/") else { return false }
        var depth = entryPath.split(separator: "/").count - 1 // directory of the link
        for component in target.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": depth -= 1
            default: depth += 1
            }
            if depth < 0 { return false }
        }
        return true
    }

    private static func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        pointer.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func errorMessage(_ archive: OpaquePointer) -> String? {
        string(archive_error_string(archive))
    }
}
