import AmeyaCore
import Foundation
import ModelIO
import SQLite3
import Testing
@testable import AmeyaEngines

/// Models that link to outside files, and inputs built to multiply memory, time or paths.
@Suite("Links and limits", .serialized)
struct ResourceLimitTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-limits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("job"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("outside"), withIntermediateDirectories: true)
    }

    // MARK: 3D models

    /// A 24-vertex box exported by Model I/O as a USD text layer.
    func box(named name: String, in folder: String) throws -> URL {
        let asset = MDLAsset()
        asset.add(MDLMesh(boxWithExtent: [1, 1, 1], segments: [1, 1, 1], inwardNormals: false, geometryType: .triangles, allocator: nil))
        let url = directory.appendingPathComponent(folder).appendingPathComponent(name)
        try asset.export(to: url)
        return url
    }

    @Test @MainActor func usdLinksOutsideAreRemoved() throws {
        let secret = try box(named: "secret.usda", in: "outside")
        let input = try box(named: "input.usda", in: "job")
        var text = try String(contentsOf: input, encoding: .utf8)
        text = text.replacingOccurrences(of: "#usda 1.0\n(\n", with: "#usda 1.0\n(\n    subLayers = [@\(secret.path)@]\n")
        text += """

        def Xform "Linked" (
            references = @\(secret.path)@
        )
        {
        }
        def Xform "Loaded" (
            payload = @../outside/secret.usda@
        )
        {
            asset texture = @/Users/someone/Pictures/private.png@
            string note = "an @ sign and @/not/a/link@ in a string"
        }
        """
        try Data(text.utf8).write(to: input)
        let (cleaned, removed) = ModelReferences.neutralizeUSDA(text)
        #expect(removed)
        #expect(!cleaned.contains(secret.path))
        #expect(!cleaned.contains("../outside"))
        #expect(!cleaned.contains("/Users/someone"))
        #expect(cleaned.contains("@/not/a/link@ in a string"))

        let output = directory.appendingPathComponent("out.usdc")
        let notes = try ModelConverter.convert(input: input, to: .usdc, output: output) { _ in }
        #expect(notes.contains(.linkedFilesLeftOut))
        // Only the model's own box: none of the three links to the outside one were followed.
        #expect(ModelConverter.vertexCount(MDLAsset(url: output)) == 24)
    }

    @Test @MainActor func binaryUSDLinkingOutsideIsRefused() throws {
        let usdcat = URL(fileURLWithPath: "/usr/bin/usdcat")
        let secret = try box(named: "secret.usda", in: "outside")
        let own = try box(named: "plain.usda", in: "job")
        // Model I/O's own binary output has a readable string table and no outside links.
        let plain = directory.appendingPathComponent("job/plain.usdc")
        try MDLAsset(url: own).export(to: plain)
        let tokens = try ModelReferences.crateTokens(Data(contentsOf: plain))
        #expect(!tokens.isEmpty)
        #expect(try ModelReferences.neutralize(plain) == false)

        guard FileManager.default.isExecutableFile(atPath: usdcat.path) else { return }
        let linking = directory.appendingPathComponent("job/linking.usda")
        try Data((try String(contentsOf: own, encoding: .utf8) + "\ndef Xform \"L\" (\n    references = @\(secret.path)@\n)\n{\n}\n").utf8).write(to: linking)
        let binary = directory.appendingPathComponent("job/input.usdc")
        let process = try Process.run(usdcat, arguments: [linking.path, "-o", binary.path])
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        #expect(try ModelReferences.crateTokens(Data(contentsOf: binary)).contains(secret.path))
        #expect(throws: ConversionError.self) {
            try ModelConverter.convert(input: binary, to: .usda, output: directory.appendingPathComponent("out.usda")) { _ in }
        }
    }

    @Test func objMaterialLibrariesOutsideAreDropped() {
        let obj = "mtllib /Users/someone/secret.mtl\nmtllib local.mtl\ncall /tmp/x.obj\nmtllib ../up.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"
        let (cleaned, removed) = ModelReferences.neutralizeOBJ(Data(obj.utf8))
        #expect(removed)
        #expect(String(decoding: cleaned, as: UTF8.self) == "mtllib local.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n")
    }

    @Test func outsidePathRules() {
        for path in ["/etc/hosts", "~/x.png", "../x.usda", "a/../../x", "file:///x", "http://h/x.usda", "C:\\x.png", "/abs/pkg.usdz[inner.usda]"] {
            #expect(ModelReferences.isOutside(path), "\(path)")
        }
        for path in ["x.usda", "./tex/a.png", "sub/x.usdc", "pkg.usdz[../inner.usda]", ""] {
            #expect(!ModelReferences.isOutside(path), "\(path)")
        }
    }

    // MARK: Images and pages

    @Test func manyFramesTogetherAreRefusedBeforeDecoding() throws {
        let gif = try Fixtures.encode(Fixtures.frames(5), as: .gif, delay: 0.1)
        let perFrame = 64 * 48
        var options = ConversionOptions()
        options.maxTotalPixels = perFrame * 4
        #expect(throws: ConversionError.tooLarge(pixels: perFrame * 5, limit: perFrame * 4)) {
            try ImageDecoder.decode(gif, options: options)
        }
        options.maxTotalPixels = perFrame * 5
        #expect(try ImageDecoder.decode(gif, options: options).frames.count == 5)
        #expect(ConversionOptions().totalPixelBudget == 1_500_000_000)
    }

    @Test func manyPagesTogetherAreRefusedBeforeRendering() throws {
        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let consumer = try #require(CGDataConsumer(data: pdf))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<3 { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        var options = ConversionOptions()
        options.maxTotalPixels = 200 * 200 * 2 // two pages at 2×
        #expect(throws: ConversionError.self) { try ImageDecoder.decode(pdf as Data, options: options) }
        options.maxTotalPixels = 200 * 200 * 3
        #expect(try ImageDecoder.decode(pdf as Data, options: options).frames.count == 3)
    }

    // MARK: Property lists

    /// A binary property list where each array holds the previous one twice: `levels` objects
    /// that expand to 2^levels values.
    static func sharedArrayBomb(levels: Int) -> Data {
        var objects: [[UInt8]] = [[0x51, UInt8(ascii: "x")]] // the string "x"
        for level in 1...levels { objects.append([0xA2, UInt8(level - 1), UInt8(level - 1)]) }
        var data = Data("bplist00".utf8)
        var offsets: [Int] = []
        for object in objects {
            offsets.append(data.count)
            data.append(contentsOf: object)
        }
        let tableOffset = data.count
        for offset in offsets { data.append(contentsOf: [UInt8(offset >> 8), UInt8(offset & 0xFF)]) }
        func be64(_ value: Int) -> [UInt8] { (0..<8).reversed().map { UInt8((value >> ($0 * 8)) & 0xFF) } }
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 2, 1] + be64(objects.count) + be64(levels) + be64(tableOffset))
        return data
    }

    @Test func sharedReferencesCantExpandWithoutLimit() throws {
        let small = Self.sharedArrayBomb(levels: 3)
        let (tree, _) = try PropertyListData.read(small)
        #expect(tree == .array([.array([.array([.string("x"), .string("x")]), .array([.string("x"), .string("x")])]),
                                .array([.array([.string("x"), .string("x")]), .array([.string("x"), .string("x")])])]))
        let bomb = Self.sharedArrayBomb(levels: 60) // 2^60 values from a file of a few hundred bytes
        #expect(bomb.count < 600)
        let start = Date()
        #expect(throws: ConversionError.self) { try PropertyListData.read(bomb) }
        #expect(Date().timeIntervalSince(start) < 30)
        #expect(throws: ConversionError.self) { try PropertyListData.read(Self.sharedArrayBomb(levels: 12), maxNodes: 1_000) }
    }

    // MARK: Archives

    @Test func chainedLinksCantEscape() throws {
        let content = directory.appendingPathComponent("payload.txt")
        try Data("data".utf8).write(to: content)
        let spec = """
        #mtree
        ./d type=dir mode=0755
        ./d/up type=link link=..
        ./d/up/x type=link link=..
        ./d/up/f.txt type=file contents=\(content.path)
        ./D/UP/g.txt type=file contents=\(content.path)
        ./e type=link link=d/up/..
        ./g/a type=link link=b/../../ok.txt
        ./g/b type=link link=..
        ./ok.txt type=file contents=\(content.path)
        ./inside type=link link=ok.txt

        """
        let specURL = directory.appendingPathComponent("links.mtree")
        try Data(spec.utf8).write(to: specURL)
        let archive = directory.appendingPathComponent("links.tar")
        let make = try Process.run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-cf", archive.path, "@" + specURL.path])
        make.waitUntilExit()
        try #require(make.terminationStatus == 0)

        let output = directory.appendingPathComponent("clean.tar")
        let notes = try ArchiveConverter.repack(input: archive, to: .tar, output: output) { _ in }
        #expect(notes.contains(.unsafeEntriesSkipped))
        let pipe = Pipe()
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        list.arguments = ["-tf", output.path]
        list.standardOutput = pipe
        try list.run()
        let names = Set(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
        list.waitUntilExit()
        #expect(names.isSuperset(of: ["d", "d/up", "ok.txt", "inside", "g/a"]))
        for escaped in ["d/up/x", "d/up/f.txt", "D/UP/g.txt", "e", "g/b"] {
            #expect(!names.contains(escaped), "\(escaped)")
        }
    }

    @Test func linkGuardRules() {
        var guardrail = ArchiveConverter.LinkGuard()
        #expect(guardrail.allows("..", at: "d/up"))
        guardrail.record("d/up", isLink: true)
        #expect(guardrail.passesThroughLink("d/up/x"))
        #expect(guardrail.passesThroughLink("D/Up"))
        #expect(!guardrail.allows("d/up/..", at: "e"))
        #expect(!guardrail.allows("/etc", at: "abs"))
        #expect(guardrail.allows("d/file.txt", at: "fine"))
    }

    // MARK: SQLite

    func database(_ sql: String) throws -> URL {
        let url = directory.appendingPathComponent("db-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ConversionError.invalidData(String(cString: sqlite3_errmsg(db)))
        }
        return url
    }

    @Test func generatedValueBombsAreRefusedQuickly() throws {
        let url = try database("""
        CREATE TABLE t (a INTEGER, b TEXT GENERATED ALWAYS AS (hex(zeroblob(400000000))) VIRTUAL);
        INSERT INTO t (a) VALUES (1);
        """)
        for target in [FileFormat.json, .csv, .sql] {
            let start = Date()
            #expect(throws: ConversionError.self, "\(target)") {
                try SQLiteConverter.convert(input: url, to: target, output: directory.appendingPathComponent("out.\(target.preferredExtension)")) { _ in }
            }
            #expect(Date().timeIntervalSince(start) < 10)
        }
    }

    @Test func slowQueriesStopAtTheDeadline() throws {
        let url = try database("""
        CREATE TABLE n (v);
        WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 200000) INSERT INTO n SELECT x FROM c;
        """)
        var limits = SQLiteConverter.Limits()
        limits.maxSeconds = 0
        #expect(throws: ConversionError.self) {
            try SQLiteConverter.convert(input: url, to: .json, output: directory.appendingPathComponent("slow.json"), limits: limits) { _ in }
        }
        // With time to spare, the same database converts.
        _ = try SQLiteConverter.convert(input: url, to: .csv, output: directory.appendingPathComponent("ok.csv")) { _ in }
    }

    @Test func schemaIsNotTrusted() throws {
        let url = try database("CREATE TABLE t (a); INSERT INTO t VALUES (1); CREATE VIEW v AS SELECT a FROM t;")
        let database = try Database(url: url)
        var trusted: Int32 = -1
        try database.query("PRAGMA trusted_schema") { trusted = sqlite3_column_int($0, 0) }
        #expect(trusted == 0)
        // Views, which could run any query when read, are switched off; tables still read.
        #expect(throws: ConversionError.self) { try database.query("SELECT * FROM v") { _ in } }
        var count = 0
        try database.forEachRow(of: "t") { _, _ in count += 1 }
        #expect(count == 1)
    }
}
