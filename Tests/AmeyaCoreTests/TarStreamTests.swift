import Foundation
import Testing
@testable import AmeyaCore

@Suite("TAR stream")
struct TarStreamTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-tar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Writes `entries` with the real writer and returns the stream's bytes.
    private func stream(_ entries: [(String, Data)]) throws -> Data {
        let url = directory.appendingPathComponent("out-\(UUID().uuidString).tar")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let writer = TarStream.Writer(handle: handle)
        for (name, data) in entries { try writer.add(name: name, data: data) }
        try writer.finish()
        try handle.close()
        return try Data(contentsOf: url)
    }

    private func extract(_ data: Data, limits: TarStream.Limits = .init()) throws -> (names: [String], folder: URL) {
        let source = directory.appendingPathComponent("in-\(UUID().uuidString).tar")
        try data.write(to: source)
        let folder = directory.appendingPathComponent("x-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        return (try TarStream.extract(from: handle, into: folder, limits: limits), folder)
    }

    /// A raw header with a correct checksum, for crafting hostile streams.
    private func header(name: String, size: Int = 0, type: UInt8 = UInt8(ascii: "0"), prefix: String = "") -> [UInt8] {
        var block = [UInt8](try! TarStream.header(name: "placeholder", size: Int64(size)))
        for index in 0..<100 { block[index] = 0 }
        for (index, byte) in name.utf8.prefix(100).enumerated() { block[index] = byte }
        for (index, byte) in prefix.utf8.enumerated() { block[345 + index] = byte }
        block[156] = type
        for index in 148..<156 { block[index] = 0x20 }
        let sum = block.reduce(0) { $0 + Int($1) }
        for (index, byte) in String(format: "%06o", sum).utf8.enumerated() { block[148 + index] = byte }
        block[154] = 0
        return block
    }

    private func raw(_ blocks: [[UInt8]], end: Bool = true) -> Data {
        var data = Data(blocks.joined())
        if end { data.append(Data(count: 1024)) }
        return data
    }

    @Test func roundTripsFilesInOrder() throws {
        let big = Data((0..<5000).map { UInt8($0 % 251) })
        let data = try stream([("0.pdf", Data("hello".utf8)), ("1.png", big), ("Page 001.pdf", Data())])
        #expect(data.count % 512 == 0)
        let (names, folder) = try extract(data)
        #expect(names == ["0.pdf", "1.png", "Page 001.pdf"])
        #expect(try Data(contentsOf: folder.appendingPathComponent("0.pdf")) == Data("hello".utf8))
        #expect(try Data(contentsOf: folder.appendingPathComponent("1.png")) == big)
        #expect(try Data(contentsOf: folder.appendingPathComponent("Page 001.pdf")).isEmpty)
    }

    @Test func writerStreamsFilesFromDisk() throws {
        let file = directory.appendingPathComponent("source.bin")
        let content = Data((0..<1300).map { UInt8($0 & 0xFF) })
        try content.write(to: file)
        let out = directory.appendingPathComponent("disk.tar")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        let written = try TarStream.write(files: [(name: "a.bin", url: file)], to: handle)
        try handle.close()
        #expect(written == Int64(try Data(contentsOf: out).count))
        let (names, folder) = try extract(try Data(contentsOf: out))
        #expect(names == ["a.bin"])
        #expect(try Data(contentsOf: folder.appendingPathComponent("a.bin")) == content)
    }

    @Test("Rejects unsafe names", arguments: ["../evil", "/etc/passwd", ".hidden", "a/b", "", "bad\nname"])
    func rejectsUnsafeNames(_ name: String) throws {
        #expect(!TarStream.isValidName(name))
        #expect(throws: TarStream.Failure.self) { try stream([(name, Data("x".utf8))]) }
        #expect(throws: TarStream.Failure.self) { try extract(raw([header(name: name)])) }
    }

    @Test func rejectsLongNamesAndPrefixes() throws {
        #expect(!TarStream.isValidName(String(repeating: "a", count: 100)))
        #expect(throws: TarStream.Failure.self) { try extract(raw([header(name: "ok.txt", prefix: "dir")])) }
    }

    @Test("Rejects links, folders and devices", arguments: ["1", "2", "5", "3", "L", "x"])
    func rejectsSpecialEntries(_ type: String) throws {
        #expect(throws: TarStream.Failure.unsupportedEntry("thing")) {
            try extract(raw([header(name: "thing", type: UInt8(ascii: Unicode.Scalar(type)!))]))
        }
    }

    @Test func rejectsBadChecksum() throws {
        var block = header(name: "a.txt")
        block[0] = UInt8(ascii: "b")
        #expect(throws: TarStream.Failure.badChecksum) { try extract(raw([block])) }
    }

    @Test func rejectsTruncatedStreams() throws {
        let full = try stream([("a.txt", Data(repeating: 7, count: 2000))])
        #expect(throws: TarStream.Failure.truncated) { try extract(full.prefix(1024)) }
        #expect(throws: TarStream.Failure.truncated) { try extract(full.dropLast(1024)) } // no end marker
        #expect(throws: TarStream.Failure.truncated) { try extract(Data()) }
    }

    @Test func enforcesLimits() throws {
        let data = try stream([("a", Data(count: 10)), ("b", Data(count: 10))])
        #expect(throws: TarStream.Failure.tooManyEntries) { try extract(data, limits: .init(maxEntries: 1)) }
        #expect(throws: TarStream.Failure.tooLarge) { try extract(data, limits: .init(maxTotalBytes: 15)) }
        // A header claiming a huge size fails on the cap before anything is read.
        #expect(throws: TarStream.Failure.tooLarge) {
            try extract(raw([header(name: "huge", size: 1 << 32)], end: false), limits: .init(maxTotalBytes: 1 << 20))
        }
    }

    @Test func rejectsDuplicates() throws {
        #expect(throws: TarStream.Failure.duplicateName("a")) { try stream([("a", Data()), ("a", Data())]) }
        let block = header(name: "a")
        #expect(throws: TarStream.Failure.duplicateName("a")) { try extract(raw([block, block])) }
    }

    @Test func neverReplacesExistingFiles() throws {
        let data = try stream([("a.txt", Data("new".utf8))])
        let source = directory.appendingPathComponent("existing.tar")
        try data.write(to: source)
        try Data("old".utf8).write(to: directory.appendingPathComponent("a.txt"))
        let handle = try FileHandle(forReadingFrom: source)
        #expect(throws: TarStream.Failure.writeFailed("a.txt")) { try TarStream.extract(from: handle, into: directory) }
        #expect(try Data(contentsOf: directory.appendingPathComponent("a.txt")) == Data("old".utf8))
    }

    @Test func encodesSizesInOctalAndBase256() throws {
        let small = try TarStream.encodeSize(1234)
        #expect(String(decoding: small.prefix(11), as: UTF8.self) == "00000002322")
        #expect(try TarStream.decodeSize(small) == 1234)

        let limit = Int64(1) << 33 // 8 GiB: the first size octal can't hold
        let octalMax = try TarStream.encodeSize(limit - 1)
        #expect(octalMax[0] != 0x80)
        #expect(try TarStream.decodeSize(octalMax) == limit - 1)

        for size in [limit, 20 << 30, Int64.max] {
            let field = try TarStream.encodeSize(size)
            #expect(field[0] == 0x80)
            #expect(try TarStream.decodeSize(field) == size)
        }
        // Negative base-256 values are rejected.
        #expect(throws: TarStream.Failure.self) { try TarStream.decodeSize([0xFF] + [UInt8](repeating: 0xFF, count: 11)) }
        #expect(throws: TarStream.Failure.self) { try TarStream.decodeSize(Array("12345678901x".utf8)) }
    }
}
