import Darwin
import Foundation

/// A deliberately small, strict ustar (POSIX tar) writer and reader for handing several files
/// between the app and the worker over a single stdin/stdout stream.
///
/// Only what Ameya itself writes is accepted: flat names (no `/`, no leading `.`, under 100 bytes),
/// regular files only, an empty prefix field, verified checksums, no duplicate names, and caps on
/// the number of entries and total bytes. Sizes are octal, or GNU base-256 from 8 GiB up.
public enum TarStream {
    public static let blockSize = 512
    static let chunkSize = 4 << 20

    public struct Limits: Sendable {
        public var maxEntries: Int
        public var maxTotalBytes: Int64
        public init(maxEntries: Int = 10_000, maxTotalBytes: Int64 = 64 << 30) {
            self.maxEntries = maxEntries
            self.maxTotalBytes = maxTotalBytes
        }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case invalidName(String)
        case unsupportedEntry(String)
        case badChecksum
        case badHeader(String)
        case truncated
        case tooManyEntries
        case tooLarge
        case duplicateName(String)
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidName(let name): "A file name in the bundle isn't allowed: \(name)"
            case .unsupportedEntry(let name): "Only plain files are allowed in the bundle (\(name))."
            case .badChecksum: "The file bundle is damaged (checksum mismatch)."
            case .badHeader(let detail): "The file bundle is damaged (\(detail))."
            case .truncated: "The file bundle ended too early."
            case .tooManyEntries: "The file bundle has too many files."
            case .tooLarge: "The file bundle is too large."
            case .duplicateName(let name): "The file bundle names \(name) twice."
            case .writeFailed(let name): "Couldn't write \(name)."
            }
        }
    }

    /// Whether `name` may appear in a stream: flat, visible, printable, under 100 UTF-8 bytes.
    public static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count < 100, !name.hasPrefix("."), !name.contains("/"),
              !name.contains("\\") else { return false }
        return !bytes.contains { $0 < 0x20 || $0 == 0x7F }
    }

    // MARK: Writing

    /// Streams regular files into a tar stream. Call `finish()` once at the end.
    public final class Writer {
        private let handle: FileHandle
        private var names: Set<String> = []
        public private(set) var bytesWritten: Int64 = 0

        public init(handle: FileHandle) {
            self.handle = handle
        }

        /// Appends the file at `url` under `name`, copying it in chunks.
        public func add(name: String, contentsOf url: URL) throws {
            guard TarStream.isValidName(name) else { throw Failure.invalidName(name) }
            guard names.insert(name).inserted else { throw Failure.duplicateName(name) }
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            let size = Int64(try reader.seekToEnd())
            try reader.seek(toOffset: 0)
            try write(TarStream.header(name: name, size: size))
            var remaining = size
            while remaining > 0 {
                let chunk = try reader.read(upToCount: Int(min(Int64(TarStream.chunkSize), remaining))) ?? Data()
                guard !chunk.isEmpty else { throw Failure.truncated } // the file shrank while copying
                try write(chunk)
                remaining -= Int64(chunk.count)
            }
            try pad(size)
        }

        /// Appends in-memory bytes under `name`.
        public func add(name: String, data: Data) throws {
            guard TarStream.isValidName(name) else { throw Failure.invalidName(name) }
            guard names.insert(name).inserted else { throw Failure.duplicateName(name) }
            try write(TarStream.header(name: name, size: Int64(data.count)))
            try write(data)
            try pad(Int64(data.count))
        }

        /// Writes the two zero blocks that end the stream.
        public func finish() throws {
            try write(Data(count: 2 * TarStream.blockSize))
        }

        private func pad(_ size: Int64) throws {
            let remainder = Int(size % Int64(TarStream.blockSize))
            if remainder != 0 { try write(Data(count: TarStream.blockSize - remainder)) }
        }

        private func write(_ data: Data) throws {
            try handle.write(contentsOf: data)
            bytesWritten += Int64(data.count)
        }
    }

    /// Writes `files` (name, source) and the end marker. Returns the bytes written.
    @discardableResult
    public static func write(files: [(name: String, url: URL)], to handle: FileHandle) throws -> Int64 {
        let writer = Writer(handle: handle)
        for file in files { try writer.add(name: file.name, contentsOf: file.url) }
        try writer.finish()
        return writer.bytesWritten
    }

    static func header(name: String, size: Int64) throws -> Data {
        var block = [UInt8](repeating: 0, count: blockSize)
        func put(_ text: String, at offset: Int) {
            for (index, byte) in text.utf8.enumerated() { block[offset + index] = byte }
        }
        put(name, at: 0)
        put("0000644", at: 100)
        put("0000000", at: 108)
        put("0000000", at: 116)
        let sizeField = try encodeSize(size)
        block.replaceSubrange(124..<136, with: sizeField)
        put("00000000000", at: 136) // mtime: 1970, so streams are reproducible
        block[156] = UInt8(ascii: "0")
        put("ustar", at: 257) // followed by NUL
        put("00", at: 263)
        // Checksum: sum of all bytes with the checksum field counted as spaces.
        for index in 148..<156 { block[index] = 0x20 }
        let sum = block.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum), at: 148)
        block[154] = 0
        block[155] = 0x20
        return Data(block)
    }

    /// The 12-byte size field: 11 octal digits and a NUL, or base-256 (high bit set) from 8 GiB up.
    public static func encodeSize(_ size: Int64) throws -> [UInt8] {
        guard size >= 0 else { throw Failure.tooLarge }
        if size < 0o77777777777 + 1 {
            return Array(String(format: "%011llo", size).utf8) + [0]
        }
        var field = [UInt8](repeating: 0, count: 12)
        var value = UInt64(size)
        for index in stride(from: 11, through: 1, by: -1) {
            field[index] = UInt8(value & 0xFF)
            value >>= 8
        }
        field[0] = 0x80
        return field
    }

    /// Reads a size field written by `encodeSize` (octal, or base-256).
    public static func decodeSize(_ field: [UInt8]) throws -> Int64 {
        guard field.count == 12 else { throw Failure.badHeader("size field") }
        if field[0] & 0x80 != 0 {
            guard field[0] == 0x80, field[1..<4].allSatisfy({ $0 == 0 }) else {
                throw Failure.badHeader("size out of range") // negative, or beyond 2^63
            }
            var value: UInt64 = 0
            for byte in field[1...] { value = (value << 8) | UInt64(byte) }
            guard value <= UInt64(Int64.max) else { throw Failure.badHeader("size out of range") }
            return Int64(value)
        }
        return try octal(field[...], what: "size")
    }

    static func octal(_ field: ArraySlice<UInt8>, what: String) throws -> Int64 {
        var value: Int64 = 0
        var digits = 0
        var ended = false
        for byte in field {
            if byte == 0 || byte == 0x20 {
                if digits > 0 { ended = true }
                continue
            }
            guard !ended, byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "7") else {
                throw Failure.badHeader("\(what) field")
            }
            value = value * 8 + Int64(byte - UInt8(ascii: "0"))
            digits += 1
        }
        guard digits > 0 else { throw Failure.badHeader("\(what) field") }
        return value
    }

    // MARK: Reading

    /// Extracts every entry into `directory` (which must exist) and returns the names in stream order.
    /// Files are created exclusively, so nothing already in `directory` is replaced.
    @discardableResult
    public static func extract(from handle: FileHandle, into directory: URL, limits: Limits = Limits()) throws -> [String] {
        var names: [String] = []
        var seen: Set<String> = []
        var total: Int64 = 0
        while true {
            let block = try readExactly(handle, count: blockSize)
            if block.allSatisfy({ $0 == 0 }) {
                let second = try readExactly(handle, count: blockSize)
                guard second.allSatisfy({ $0 == 0 }) else { throw Failure.badHeader("end marker") }
                return names
            }
            let (name, size) = try parseHeader(block)
            guard seen.insert(name).inserted else { throw Failure.duplicateName(name) }
            guard names.count < limits.maxEntries else { throw Failure.tooManyEntries }
            total += size
            guard total <= limits.maxTotalBytes else { throw Failure.tooLarge }

            let url = directory.appendingPathComponent(name, isDirectory: false)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            guard fd >= 0 else { throw Failure.writeFailed(name) }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var remaining = size
            while remaining > 0 {
                let chunk = try readExactly(handle, count: Int(min(Int64(chunkSize), remaining)))
                try output.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
            try output.close()
            let padding = Int((Int64(blockSize) - size % Int64(blockSize)) % Int64(blockSize))
            if padding > 0 { _ = try readExactly(handle, count: padding) }
            names.append(name)
        }
    }

    /// Validates one header block and returns the entry's name and size.
    static func parseHeader(_ block: [UInt8]) throws -> (name: String, size: Int64) {
        guard block.count == blockSize else { throw Failure.truncated }
        let stored = try octal(block[148..<156], what: "checksum")
        var sum = 0
        for (index, byte) in block.enumerated() { sum += (148..<156).contains(index) ? 0x20 : Int(byte) }
        guard stored == sum else { throw Failure.badChecksum }
        guard Array(block[257..<263]) == Array("ustar\0".utf8), Array(block[263..<265]) == Array("00".utf8) else {
            throw Failure.badHeader("not a POSIX ustar header")
        }
        let nameBytes = block[0..<100].prefix { $0 != 0 }
        guard let name = String(bytes: nameBytes, encoding: .utf8) else { throw Failure.invalidName("(not UTF-8)") }
        guard block[345..<500].allSatisfy({ $0 == 0 }) else { throw Failure.invalidName(name + " (prefix)") }
        guard isValidName(name) else { throw Failure.invalidName(name) }
        let type = block[156]
        guard type == UInt8(ascii: "0") || type == 0 else { throw Failure.unsupportedEntry(name) }
        return (name, try decodeSize(Array(block[124..<136])))
    }

    static func readExactly(_ handle: FileHandle, count: Int) throws -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        while bytes.count < count {
            guard let chunk = try handle.read(upToCount: count - bytes.count), !chunk.isEmpty else {
                throw Failure.truncated
            }
            bytes.append(contentsOf: chunk)
        }
        return bytes
    }
}
