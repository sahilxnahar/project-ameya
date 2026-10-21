import AmeyaCore
import CArchive
import Foundation

/// Why an e-book or comic couldn't be converted.
public enum BookError: Error, Equatable, LocalizedError {
    case drmProtected
    case notABook(String)
    case missingPart(String)
    case passwordProtected
    case tooLarge(megabytes: Int64)
    case tooManyEntries(limit: Int)
    case noPages
    case tooManyPages(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .drmProtected: "This book is DRM-protected, so it can't be converted. Only DRM-free books can be read."
        case .notABook(let reason): "This isn't a valid EPUB: \(reason)."
        case .missingPart(let path): "The book is incomplete: \(path) is missing."
        case .passwordProtected: "Password-protected files aren't supported yet."
        case .tooLarge(let megabytes): "The file unpacks to more than \(megabytes) MB."
        case .tooManyEntries(let limit): "The file has more than \(limit) entries."
        case .noPages: "No pictures were found in this comic."
        case .tooManyPages(let limit): "There are more than \(limit) pages."
        }
    }
}

/// Selected entries of an archive, read into memory through libarchive. Used where parts must
/// be looked up by name (EPUB) or sorted before use (comics). Paths are made safe with the same
/// rules as archive repacking, and total size is capped so a small file can't exhaust memory.
struct ArchiveEntries {
    struct Limits {
        var maxEntries = 20_000
        var maxTotalBytes: Int64 = 500 << 20
    }

    private(set) var files: [String: Data] = [:]
    /// Paths of the files read, in archive order.
    private(set) var paths: [String] = []
    /// Regular files that `include` turned down.
    private(set) var excluded: [String] = []
    /// Whether entries with absolute or `..` paths were ignored.
    private(set) var unsafeSkipped = false
    private var caseFolded: [String: String] = [:]

    /// The file at `path`. Falls back to a case-insensitive match, because books made on
    /// case-insensitive disks often reference "Images/Cover.jpg" as "images/cover.jpg".
    subscript(path: String) -> Data? {
        files[path] ?? caseFolded[path.lowercased()].flatMap { files[$0] }
    }

    static func read(_ url: URL, limits: Limits = Limits(), include: (String) -> Bool = { _ in true }) throws -> ArchiveEntries {
        guard let reader = archive_read_new() else { throw ConversionError.mediaFailed("libarchive unavailable") }
        defer { archive_read_free(reader) }
        archive_read_support_filter_all(reader)
        archive_read_support_format_all(reader)
        guard archive_read_open_filename(reader, url.path, 64 * 1024) == ARCHIVE_OK else {
            throw ConversionError.unreadable
        }

        var result = ArchiveEntries()
        var total: Int64 = 0
        var count = 0
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var entry: OpaquePointer?
        while true {
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status >= ARCHIVE_WARN, let entry else {
                throw count == 0 ? ConversionError.unreadable : ConversionError.mediaFailed("the file is damaged")
            }
            count += 1
            guard count <= limits.maxEntries else { throw BookError.tooManyEntries(limit: limits.maxEntries) }
            guard archive_entry_filetype(entry) & mode_t(AE_IFMT) == mode_t(AE_IFREG) else { continue }
            guard let raw = string(archive_entry_pathname_utf8(entry)) ?? string(archive_entry_pathname(entry)),
                  let path = ArchiveConverter.safePath(raw) else {
                result.unsafeSkipped = true
                continue
            }
            guard include(path) else {
                result.excluded.append(path)
                continue
            }
            if archive_entry_is_encrypted(entry) != 0 { throw BookError.passwordProtected }

            // Check the declared size first, then the real one: headers can lie.
            let tooLarge = BookError.tooLarge(megabytes: limits.maxTotalBytes >> 20)
            var data = Data()
            if archive_entry_size_is_set(entry) != 0 {
                let declared = archive_entry_size(entry)
                guard declared >= 0, total + declared <= limits.maxTotalBytes else { throw tooLarge }
                data.reserveCapacity(Int(declared))
            }
            while true {
                let read = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                if read == 0 { break }
                guard read > 0 else { throw ConversionError.mediaFailed(string(archive_error_string(reader)) ?? "the file is damaged") }
                total += Int64(read)
                guard total <= limits.maxTotalBytes else { throw tooLarge }
                data.append(contentsOf: buffer[0..<read])
            }
            if result.files.updateValue(data, forKey: path) == nil { result.paths.append(path) }
            result.caseFolded[path.lowercased()] = path
        }
        return result
    }

    private static func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        pointer.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}
