import Foundation
import ImageIO
import ModelIO
import SQLite3
import Testing
@testable import AmeyaCore
@testable import AmeyaEngines

/// A fresh temporary folder, removed by the caller.
private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-qw-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("3D models")
@MainActor
struct ModelConverterTests {
    /// A unit cube written by Model I/O: 24 vertices (4 per face, for flat normals), 12 triangles.
    func cube(in folder: URL, as format: FileFormat = .obj) throws -> URL {
        let mesh = MDLMesh(boxWithExtent: [1, 1, 1], segments: [1, 1, 1], inwardNormals: false,
                           geometryType: .triangles, allocator: nil)
        let asset = MDLAsset()
        asset.add(mesh)
        let url = folder.appendingPathComponent("input.\(format.preferredExtension)")
        try asset.export(to: url)
        return url
    }

    /// STL stores every triangle's corners separately, so the cube has 36 vertices there.
    func expectedVertices(_ format: FileFormat) -> Int { format == .stl ? 36 : 24 }

    /// Triangles across every mesh: the geometry that must survive any conversion.
    func triangles(_ url: URL) -> Int {
        MDLAsset(url: url).childObjects(of: MDLMesh.self).reduce(0) { total, object in
            total + ((object as? MDLMesh)?.submeshes as? [MDLSubmesh] ?? []).reduce(0) { $0 + $1.indexCount / 3 }
        }
    }

    @Test("A cube survives conversion to every writable model format and back to OBJ")
    func convertsAcrossFormats() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let obj = try cube(in: folder)
        let writable = FileFormat.allCases.filter { $0.family == .model && FileFormat.modelWritable($0) }
        #expect(Set(writable).isSuperset(of: [.usdz, .usda, .usdc, .obj, .stl, .ply]))

        for target in writable where target != .obj {
            let output = folder.appendingPathComponent("out-\(target.rawValue).\(target.preferredExtension)")
            let notes = try ModelConverter.convert(input: obj, to: target, output: output) { _ in }
            #expect(notes.contains(.materialsMayNotCarryOver))
            #expect(FileFormat.detect(at: output) == target, "\(target) output detected wrongly")
            let reloaded = MDLAsset(url: output)
            #expect(ModelConverter.vertexCount(reloaded) == expectedVertices(target), "\(target)")
            #expect(triangles(output) == 12, "\(target)")

            // And back again, from the new format.
            let back = folder.appendingPathComponent("back-\(target.rawValue).obj")
            _ = try ModelConverter.convert(input: output, to: .obj, output: back) { _ in }
            // OBJ merges corners that share a position and normal, so count triangles instead.
            #expect(triangles(back) == 12, "\(target) → OBJ")
        }
    }

    @Test func objOutputHasNoDanglingMaterialLibrary() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ply = try cube(in: folder, as: .ply)
        let output = folder.appendingPathComponent("out.obj")
        _ = try ModelConverter.convert(input: ply, to: .obj, output: output) { _ in }
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(!text.contains("mtllib"))
        #expect(text.contains("\nv "))
    }

    @Test func alembicIsReadable() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let abc = try cube(in: folder, as: .abc)
        #expect(FileFormat.detect(at: abc) == .abc)
        let output = folder.appendingPathComponent("out.usdc")
        _ = try ModelConverter.convert(input: abc, to: .usdc, output: output) { _ in }
        #expect(ModelConverter.vertexCount(MDLAsset(url: output)) > 0)
    }

    @Test func rendersAFramedPreview() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let obj = try cube(in: folder)
        let output = folder.appendingPathComponent("preview.png")
        _ = try ModelConverter.convert(input: obj, to: .png, output: output) { _ in }
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width >= ModelConverter.previewSize && image.width == image.height)

        // The cube is drawn: the centre differs from the background in the corner.
        let context = Fixtures.context(width: 16, height: 16)
        context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let row = context.bytesPerRow
        let corner = Array(UnsafeBufferPointer(start: pixels, count: 3))
        let centre = Array(UnsafeBufferPointer(start: pixels + 8 * row + 8 * 4, count: 3))
        #expect(corner != centre)
    }

    @Test func rejectsFilesWithoutGeometry() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let empty = folder.appendingPathComponent("input.obj")
        try Data("# nothing here\n".utf8).write(to: empty)
        #expect(throws: ConversionError.self) {
            try ModelConverter.convert(input: empty, to: .stl, output: folder.appendingPathComponent("out.stl")) { _ in }
        }
    }
}

@Suite("Single-file compression")
struct SingleFileCompressionTests {
    /// Mixed content: compressible text and incompressible pseudo-random bytes.
    static let payload: Data = {
        var generator = SystemRandomNumberGenerator()
        var data = Data(String(repeating: "Ameya compresses this line. ", count: 4_000).utf8)
        data.append(contentsOf: (0..<200_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        return data
    }()

    @Test("Compress then decompress gives back identical bytes", arguments: [FileFormat.gz, .bz2, .xz])
    func roundTrip(format: FileFormat) throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("report.pdf")
        try Self.payload.write(to: original)

        let compressed = folder.appendingPathComponent("report.pdf.\(format.preferredExtension)")
        _ = try SingleFileCompression.convert(input: original, from: .other, to: format, output: compressed) { _ in }
        #expect(FileFormat.detect(at: compressed) == format)
        #expect(ConversionMatrix.canConvert(from: format, to: .decompressed))

        let restored = folder.appendingPathComponent("restored.bin")
        _ = try SingleFileCompression.convert(input: compressed, from: format, to: .decompressed, output: restored) { _ in }
        #expect(try Data(contentsOf: restored) == Self.payload)

        // The original name comes back.
        let out = folder.appendingPathComponent("out", isDirectory: true)
        #expect(OutputPlanner.destination(for: compressed, target: .decompressed, in: out) { _ in false }.lastPathComponent == "report.pdf")
    }

    /// The app decides TAR or single file from the name alone (it never decompresses to look),
    /// so a misnamed TAR arrives as a single compressed file. Decompressing it in the worker
    /// gives back the TAR byte for byte and says that it is one.
    @Test func misnamedTarArchivesDecompressToTheTarWithANote() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = folder.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: plain)
        let tar = folder.appendingPathComponent("bundle.tar")
        try runTar(["-cf", tar.path, "-C", folder.path, "a.txt"])

        for (flag, single, archive) in [("z", "gz", FileFormat.tgz), ("j", "bz2", .tbz2), ("J", "xz", .txz)] {
            let format = FileFormat(rawValue: single)!
            let tarball = folder.appendingPathComponent("bundle.\(single)") // misleadingly named
            try runTar(["-c\(flag)f", tarball.path, "-C", folder.path, "a.txt"])
            #expect(FileFormat.detect(at: tarball) == format, "\(single) holding a TAR, judged by name")
            let named = folder.appendingPathComponent("bundle.tar.\(single)")
            try FileManager.default.copyItem(at: tarball, to: named)
            #expect(FileFormat.detect(at: named) == archive)

            let restored = folder.appendingPathComponent("restored-\(single)")
            let notes = try SingleFileCompression.convert(input: tarball, from: format, to: .decompressed, output: restored) { _ in }
            #expect(notes == [.heldTarArchive])
            #expect(try Data(contentsOf: restored) == Data(contentsOf: tar))

            // A single compressed file stays single, without a TAR note, whatever its name.
            let lone = folder.appendingPathComponent("blob-\(single).data")
            _ = try SingleFileCompression.convert(input: plain, from: .txt, to: format, output: lone) { _ in }
            #expect(FileFormat.detect(at: lone) == format)
            let back = folder.appendingPathComponent("back-\(single)")
            #expect(try SingleFileCompression.convert(input: lone, from: format, to: .decompressed, output: back) { _ in }.isEmpty)
        }
    }

    @Test func tarHeaderCheck() {
        var block = [UInt8](repeating: 0, count: 512)
        #expect(!SingleFileCompression.isTarHeader(Data(block)))
        block.replaceSubrange(0..<5, with: Array("a.txt".utf8))
        let sum = block.enumerated().reduce(0) { $0 + (($1.offset >= 148 && $1.offset < 156) ? 0x20 : Int($1.element)) }
        block.replaceSubrange(148..<156, with: Array(String(format: "%06o\0 ", sum).utf8))
        #expect(SingleFileCompression.isTarHeader(Data(block)))
        block[0] = UInt8(ascii: "b") // checksum no longer matches
        #expect(!SingleFileCompression.isTarHeader(Data(block)))
        #expect(!SingleFileCompression.isTarHeader(Data("hello".utf8)))
    }

    private func runTar(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
    }

    @Test func decompressionBombsAreStopped() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let zeros = folder.appendingPathComponent("zeros")
        try Data(count: 8 << 20).write(to: zeros)
        let compressed = folder.appendingPathComponent("zeros.gz")
        _ = try SingleFileCompression.convert(input: zeros, from: .other, to: .gz, output: compressed) { _ in }

        let output = folder.appendingPathComponent("out")
        let tooBig = SingleFileCompression.Limits(maxTotalBytes: 1 << 20)
        #expect(throws: ConversionError.self) {
            try SingleFileCompression.convert(input: compressed, from: .gz, to: .decompressed, output: output, limits: tooBig) { _ in }
        }
        let ratio = SingleFileCompression.Limits(maxRatio: 50, ratioCheckAfter: 1 << 20)
        #expect(throws: ConversionError.self) {
            try SingleFileCompression.convert(input: compressed, from: .gz, to: .decompressed, output: output, limits: ratio) { _ in }
        }
    }

    @Test func uncompressedDataIsRejected() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = folder.appendingPathComponent("fake.gz")
        try Data("not compressed at all".utf8).write(to: fake)
        #expect(throws: ConversionError.self) {
            try SingleFileCompression.convert(input: fake, from: .gz, to: .decompressed, output: folder.appendingPathComponent("o")) { _ in }
        }
    }
}

@Suite("SQLite")
struct SQLiteConverterTests {
    /// Three tables: one with every storage class, an empty one, and one with an awkward name.
    static func makeDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        let sql = #"""
        CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, score REAL, photo BLOB, note TEXT);
        INSERT INTO people VALUES (1, 'Ada', 9.5, x'00FF10', NULL);
        INSERT INTO people VALUES (2, 'Zoë "Z", 日本', 2.0, NULL, 'multi' || char(10) || 'line');
        INSERT INTO people VALUES (3, 'O''Brien', -1e300, x'', 'x');
        CREATE TABLE empty (x);
        CREATE TABLE "odd ""name""" (v);
        INSERT INTO "odd ""name""" VALUES (42);
        CREATE INDEX people_name ON people(name);
        CREATE VIEW adults AS SELECT name FROM people;
        """#
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ConversionError.invalidData(String(cString: sqlite3_errmsg(db)))
        }
    }

    func withDatabase(_ body: (URL, URL) throws -> Void) throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("input.sqlite")
        try Self.makeDatabase(at: url)
        let before = try Data(contentsOf: url)
        try body(url, folder)
        #expect(try Data(contentsOf: url) == before, "the database must never be modified")
    }

    @Test func detectsDatabasesByContent() throws {
        try withDatabase { url, folder in
            #expect(FileFormat.detect(at: url) == .sqlite)
            let renamed = folder.appendingPathComponent("mystery.db")
            try FileManager.default.copyItem(at: url, to: renamed)
            #expect(FileFormat.detect(at: renamed) == .sqlite)
        }
    }

    @Test func csvHoldsTheLargestTable() throws {
        try withDatabase { url, folder in
            let output = folder.appendingPathComponent("out.csv")
            let notes = try SQLiteConverter.convert(input: url, to: .csv, output: output) { _ in }
            #expect(notes == [.onlyLargestTableKept, .binaryAsBase64])
            let text = try String(contentsOf: output, encoding: .utf8)
            #expect(text == "id,name,score,photo,note\r\n1,Ada,9.5,AP8Q,\r\n"
                + "2,\"Zoë \"\"Z\"\", 日本\",2.0,,\"multi\nline\"\r\n3,O'Brien,-1.0e+300,,x\r\n")
        }
    }

    @Test func jsonHoldsEveryTable() throws {
        try withDatabase { url, folder in
            let output = folder.appendingPathComponent("out.json")
            _ = try SQLiteConverter.convert(input: url, to: .json, output: output) { _ in }
            let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: [[String: Any]]])
            #expect(Set(root.keys) == ["people", "empty", "odd \"name\""])
            let people = try #require(root["people"])
            #expect(people.count == 3)
            #expect(people[0]["photo"] as? String == "AP8Q")
            #expect(people[0]["note"] is NSNull)
            #expect(people[0]["score"] as? Double == 9.5)
            #expect(people[1]["name"] as? String == "Zoë \"Z\", 日本")
            #expect(root["empty"]?.isEmpty == true)
            #expect(root["odd \"name\""]?.first?["v"] as? Int == 42)
        }
    }

    @Test func sqlDumpRebuildsTheSameDatabase() throws {
        try withDatabase { url, folder in
            let output = folder.appendingPathComponent("out.sql")
            _ = try SQLiteConverter.convert(input: url, to: .sql, output: output) { _ in }
            let dump = try String(contentsOf: output, encoding: .utf8)
            #expect(dump.hasPrefix("PRAGMA foreign_keys=OFF;\nBEGIN TRANSACTION;\n"))
            #expect(dump.hasSuffix("COMMIT;\n"))
            #expect(dump.contains("X'00FF10'"))
            #expect(dump.contains("CREATE VIEW adults"))

            var copy: OpaquePointer?
            #expect(sqlite3_open(":memory:", &copy) == SQLITE_OK)
            defer { sqlite3_close(copy) }
            #expect(sqlite3_exec(copy, dump, nil, nil, nil) == SQLITE_OK)
            let original = try Database(url: url)
            let rebuilt = folder.appendingPathComponent("rebuilt.sqlite")
            #expect(sqlite3_exec(copy, "VACUUM INTO '\(rebuilt.path)'", nil, nil, nil) == SQLITE_OK)
            let restored = try Database(url: rebuilt)
            for table in try original.tables() {
                var a: [[DataValue]] = [], b: [[DataValue]] = []
                try original.forEachRow(of: table.name) { values, _ in a.append(values) }
                try restored.forEachRow(of: table.name) { values, _ in b.append(values) }
                #expect(a == b, "\(table.name)")
            }
            var types: [String] = []
            try restored.query("SELECT typeof(score) FROM people ORDER BY id") { types.append(Database.text($0, 0) ?? "") }
            #expect(types == ["real", "real", "real"])
        }
    }

    @Test func rowLimitIsEnforced() throws {
        try withDatabase { url, folder in
            let limits = SQLiteConverter.Limits(maxRows: 2)
            #expect(throws: ConversionError.self) {
                try SQLiteConverter.convert(input: url, to: .json, output: folder.appendingPathComponent("o.json"), limits: limits) { _ in }
            }
        }
    }

    @Test func damagedFilesAreRejected() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("bad.sqlite")
        try (Data("SQLite format 3\0".utf8) + Data(repeating: 0xAB, count: 4096)).write(to: url)
        #expect(throws: ConversionError.self) {
            try SQLiteConverter.convert(input: url, to: .csv, output: folder.appendingPathComponent("o.csv")) { _ in }
        }
    }
}
