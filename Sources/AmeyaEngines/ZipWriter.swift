import AmeyaCore
import Compression
import Foundation

/// A minimal ZIP writer for EPUB and CBZ output.
///
/// libarchive's ZIP writer always adds "ux"/"UT" extra fields and a data descriptor, and EPUB's
/// container rules (OCF) forbid both on the first entry: `mimetype` must be stored, with no extra
/// field, so that "application/epub+zip" sits at byte 38 where readers look for it. Writing the
/// few structures ourselves gives that control. Entries are streamed to disk one at a time; only
/// the central directory is kept in memory. No ZIP64: output is capped at 4 GB.
struct ZipWriter {
    enum Method { case store, deflate }

    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var directory = Data()
    private var count = 0
    private let time: UInt16
    private let date: UInt16

    init(url: URL, modified: Date = Date()) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ConversionError.mediaFailed("couldn't create the output file")
        }
        handle = try FileHandle(forWritingTo: url)
        // MS-DOS time: 2-second resolution, local time, years from 1980.
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: modified)
        time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        date = UInt16(max(0, (parts.year ?? 1980) - 1980) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
    }

    mutating func add(_ path: String, _ data: Data, method: Method = .deflate) throws {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        var body = data
        var methodCode: UInt16 = 0
        if method == .deflate, let packed = Self.deflate(data) {
            body = packed
            methodCode = 8
        }
        guard data.count < Int(UInt32.max), offset + UInt64(body.count) + 1024 < UInt64(UInt32.max),
              count < Int(UInt16.max), name.count < Int(UInt16.max) else {
            throw ConversionError.mediaFailed("the output would be larger than 4 GB")
        }
        // Bit 11 marks UTF-8 names; plain ASCII names (like `mimetype`) leave it clear.
        let flags: UInt16 = path.utf8.allSatisfy { $0 < 0x80 } ? 0 : 0x0800

        var local = Data()
        local.append32(0x0403_4B50)
        local.append16(20) // version needed: 2.0
        local.append16(flags)
        local.append16(methodCode)
        local.append16(time)
        local.append16(date)
        local.append32(crc)
        local.append32(UInt32(body.count))
        local.append32(UInt32(data.count))
        local.append16(UInt16(name.count))
        local.append16(0) // no extra field
        local.append(name)
        try handle.write(contentsOf: local)
        try handle.write(contentsOf: body)

        directory.append32(0x0201_4B50)
        directory.append16(0x0314) // made by: Unix, 2.0
        directory.append16(20)
        directory.append16(flags)
        directory.append16(methodCode)
        directory.append16(time)
        directory.append16(date)
        directory.append32(crc)
        directory.append32(UInt32(body.count))
        directory.append32(UInt32(data.count))
        directory.append16(UInt16(name.count))
        directory.append16(0) // extra
        directory.append16(0) // comment
        directory.append16(0) // disk
        directory.append16(0) // internal attributes
        directory.append32(0o100644 << 16) // regular file, rw-r--r--
        directory.append32(UInt32(offset))
        directory.append(name)

        offset += UInt64(local.count + body.count)
        count += 1
    }

    /// Writes the central directory and closes the file.
    mutating func finish() throws {
        defer { try? handle.close() }
        var end = Data()
        end.append32(0x0605_4B50)
        end.append16(0)
        end.append16(0)
        end.append16(UInt16(count))
        end.append16(UInt16(count))
        end.append32(UInt32(directory.count))
        end.append32(UInt32(offset))
        end.append16(0) // comment length
        try handle.write(contentsOf: directory)
        try handle.write(contentsOf: end)
    }

    /// Raw DEFLATE (what ZIP stores), or nil when compressing doesn't make the data smaller.
    static func deflate(_ data: Data) -> Data? {
        guard data.count > 64 else { return nil }
        var output = Data(count: data.count)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB // Apple's ZLIB encoder emits raw DEFLATE, without a zlib header
                )
            }
        }
        guard written > 0, written < data.count else { return nil }
        return output.prefix(written)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { bytes in
            table.withUnsafeBufferPointer { table in
                for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
            }
        }
        return ~crc
    }
}

private extension Data {
    mutating func append16(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    mutating func append32(_ value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)])
    }
}
