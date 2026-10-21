import AmeyaCore
import CArchive
import Foundation

/// Compresses one file to .gz, .bz2 or .xz, and decompresses those back to the original bytes,
/// streaming through the system libarchive's "raw" format (a single unnamed entry).
///
/// The worker never sees file names, so the original name is restored by `OutputPlanner`
/// (from the compressed file's name, or the gzip header). Decompression is capped like
/// `ArchiveConverter`: total size, and an expansion-ratio guard against bombs.
///
/// The app tells a single compressed file from a compressed TAR by name only (it never looks
/// inside), so a TAR can arrive here under a plain ".gz" name. Decompressing still gives the
/// user exactly the bytes inside; when those are a TAR archive the result says so.
enum SingleFileCompression {
    struct Limits {
        var maxTotalBytes: Int64 = 16 << 30 // 16 GiB decompressed
        var maxRatio: Int64 = 250 // decompressed ÷ compressed, checked once past `ratioCheckAfter`
        var ratioCheckAfter: Int64 = 1 << 30
    }

    static func convert(input: URL, from source: FileFormat, to target: FileFormat, output: URL,
                        limits: Limits = Limits(), progress: (Double) -> Void) throws -> [ConversionNote] {
        var notes: [ConversionNote] = []
        if target == .decompressed {
            if try decompress(input: input, from: source, output: output, limits: limits, progress: progress) {
                notes.append(.heldTarArchive)
            }
        } else {
            try compress(input: input, to: target, output: output, progress: progress)
        }
        progress(1)
        return notes
    }

    static func compress(input: URL, to target: FileFormat, output: URL, progress: (Double) -> Void) throws {
        guard let writer = archive_write_new() else { throw ConversionError.mediaFailed("libarchive unavailable") }
        defer { archive_write_free(writer) }
        let filter: Int32 = switch target {
        case .gz: archive_write_add_filter_gzip(writer)
        case .bz2: archive_write_add_filter_bzip2(writer)
        case .xz: archive_write_add_filter_xz(writer)
        default: throw ConversionError.unsupportedTarget(target)
        }
        guard filter == ARCHIVE_OK, archive_write_set_format_raw(writer) == ARCHIVE_OK,
              archive_write_open_filename(writer, output.path) == ARCHIVE_OK else {
            throw ConversionError.encodeFailed(target)
        }

        let reader: FileHandle
        do { reader = try FileHandle(forReadingFrom: input) } catch { throw ConversionError.unreadable }
        defer { try? reader.close() }
        let size = Int64((try? FileManager.default.attributesOfItem(atPath: input.path)[.size] as? Int) ?? 0)

        guard let entry = archive_entry_new() else { throw ConversionError.mediaFailed("out of memory") }
        defer { archive_entry_free(entry) }
        archive_entry_set_pathname_utf8(entry, "data")
        archive_entry_set_filetype(entry, UInt32(AE_IFREG))
        archive_entry_set_perm(entry, 0o644)
        archive_entry_set_size(entry, size)
        guard archive_write_header(writer, entry) >= ARCHIVE_WARN else {
            throw ConversionError.mediaFailed(message(writer) ?? "couldn't start the compressed file")
        }

        var done: Int64 = 0
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            let written = chunk.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) }
            guard written == chunk.count else {
                throw ConversionError.mediaFailed(message(writer) ?? "couldn't write compressed data")
            }
            done += Int64(chunk.count)
            progress(min(0.99, Double(done) / Double(max(size, 1))))
        }
        guard archive_write_close(writer) == ARCHIVE_OK else {
            throw ConversionError.mediaFailed(message(writer) ?? "couldn't finish the compressed file")
        }
    }

    /// Decompresses `input` to `output` and returns whether the result is a TAR archive.
    @discardableResult
    static func decompress(input: URL, from source: FileFormat, output: URL, limits: Limits, progress: (Double) -> Void) throws -> Bool {
        let expected: Int32 = switch source {
        case .gz: ARCHIVE_FILTER_GZIP
        case .bz2: ARCHIVE_FILTER_BZIP2
        case .xz: ARCHIVE_FILTER_XZ
        default: throw ConversionError.unsupportedConversion(from: source, to: .decompressed)
        }
        guard let reader = archive_read_new() else { throw ConversionError.mediaFailed("libarchive unavailable") }
        defer { archive_read_free(reader) }
        archive_read_support_filter_gzip(reader)
        archive_read_support_filter_bzip2(reader)
        archive_read_support_filter_xz(reader)
        archive_read_support_format_raw(reader)
        guard archive_read_open_filename(reader, input.path, 64 * 1024) == ARCHIVE_OK else { throw ConversionError.unreadable }
        var entry: OpaquePointer?
        guard archive_read_next_header(reader, &entry) >= ARCHIVE_WARN else {
            throw ConversionError.invalidData(message(reader) ?? "it isn't a valid \(source.displayName) file")
        }
        // Filter 0 is the outermost decompressor; "none" means the bytes weren't compressed at all.
        guard archive_filter_count(reader) > 1, archive_filter_code(reader, 0) == expected else {
            throw ConversionError.invalidData("it isn't a valid \(source.displayName) file")
        }

        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer: FileHandle
        do { writer = try FileHandle(forWritingTo: output) } catch { throw ConversionError.mediaFailed("couldn't create the output") }
        defer { try? writer.close() }

        let compressedSize = Int64((try? FileManager.default.attributesOfItem(atPath: input.path)[.size] as? Int) ?? 1)
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var total: Int64 = 0
        var head = Data() // the first TAR block's worth of output
        while true {
            let read = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
            if read == 0 { return isTarHeader(head) }
            guard read > 0 else { throw ConversionError.invalidData(message(reader) ?? "the compressed data is damaged") }
            total += Int64(read)
            guard total <= limits.maxTotalBytes else {
                throw ConversionError.dataLimit("it decompresses to more than \(limits.maxTotalBytes >> 30) GB")
            }
            if total > limits.ratioCheckAfter && total / max(compressedSize, 1) > limits.maxRatio {
                throw ConversionError.dataLimit("it expands suspiciously (possible decompression bomb)")
            }
            if head.count < 512 { head.append(contentsOf: buffer[0..<min(read, 512 - head.count)]) }
            try writer.write(contentsOf: Data(buffer[0..<read]))
            progress(min(0.99, Double(archive_filter_bytes(reader, -1)) / Double(max(compressedSize, 1))))
        }
    }

    /// Whether `block` is a valid TAR header (ustar, GNU or old V7): a name, and a checksum
    /// field matching the sum of the header bytes with that field counted as spaces.
    static func isTarHeader(_ block: Data) -> Bool {
        let bytes = [UInt8](block)
        guard bytes.count >= 512, bytes[0] != 0 else { return false }
        let digits = bytes[148..<156].drop { $0 == 0x20 }.prefix { $0 != 0 && $0 != 0x20 }
        guard !digits.isEmpty, digits.allSatisfy({ (0x30...0x37).contains($0) }),
              let stored = Int(String(decoding: digits, as: UTF8.self), radix: 8) else { return false }
        var sum = 0
        for (index, byte) in bytes[0..<512].enumerated() {
            sum += (148..<156).contains(index) ? 0x20 : Int(byte)
        }
        return sum == stored
    }

    private static func message(_ archive: OpaquePointer) -> String? {
        archive_error_string(archive).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}
