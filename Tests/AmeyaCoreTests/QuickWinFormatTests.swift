import Foundation
import Testing
@testable import AmeyaCore

@Suite("3D models, compression and SQLite: detection, routing and naming")
struct QuickWinFormatTests {
    @Test("Signatures", arguments: [
        (Array("SQLite format 3\0".utf8), FileFormat.sqlite),
        (Array("PXR-USDC".utf8) + [0, 8], .usdc),
        (Array("#usda 1.0\n".utf8), .usda),
        (Array("ply\nformat ascii 1.0".utf8), .ply),
        (Array("ply \nformat binary_little_endian 1.0".utf8), .ply),
        (Array("Ogawa".utf8) + [0xFF, 0, 1], .abc),
    ] as [([UInt8], FileFormat)])
    func sniff(bytes: [UInt8], expected: FileFormat) {
        #expect(FileFormat.sniff(Data(bytes)) == expected)
    }

    @Test func extensionsBreakTiesForModels() {
        var zip: [UInt8] = [0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0, count: 26)
        zip[26] = 10
        zip += Array("scene.usdc".utf8)
        #expect(FileFormat.detect(header: Data(zip), fileExtension: "zip") == .usdz) // by contents
        #expect(FileFormat.detect(header: Data([0x50, 0x4B, 0x03, 0x04]), fileExtension: "usdz") == .usdz)
        #expect(FileFormat.detect(header: Data(repeating: 0x20, count: 84), fileExtension: "stl") == .stl)
        #expect(FileFormat.detect(header: Data("v 0 0 0\nf 1 2 3\n".utf8), fileExtension: "obj") == .obj)
        #expect(FileFormat.fromExtension("usd") == .usdc)
        #expect(FileFormat.fromExtension("db") == .sqlite)
        #expect(FileFormat.fromExtension("gz") == .gz)
        #expect(FileFormat.fromExtension("tgz") == .tgz)
    }

    @Test func gzipTellsTARFromSingleFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("notes.txt")
        try Data(String(repeating: "hello ", count: 100).utf8).write(to: text)

        func run(_ tool: String, _ arguments: [String], stdout: URL? = nil) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            if let stdout {
                FileManager.default.createFile(atPath: stdout.path, contents: nil)
                process.standardOutput = try FileHandle(forWritingTo: stdout)
            }
            try process.run()
            process.waitUntilExit()
        }
        let single = folder.appendingPathComponent("notes.txt.gz")
        try run("/usr/bin/gzip", ["-c", text.path], stdout: single)
        let tarball = folder.appendingPathComponent("bundle.gz")
        try run("/usr/bin/tar", ["-czf", tarball.path, "-C", folder.path, "notes.txt"])
        let named = folder.appendingPathComponent("bundle.tar.gz")
        try FileManager.default.copyItem(at: single, to: named)

        #expect(FileFormat.detect(at: single) == .gz)
        // The app never decompresses to look inside: a TAR under a plain ".gz" name is a
        // "compressed file" (Decompress), and the worker says when the result is a TAR.
        #expect(FileFormat.detect(at: tarball) == .gz)
        #expect(FileFormat.detect(at: named) == .tgz) // ".tar.gz" names are trusted
        #expect(FileFormat.detect(header: try Data(contentsOf: single), fileExtension: "gz") == .tgz) // header alone can't tell

        // gzip stores the original name; it's used when the file name has lost it.
        let renamed = folder.appendingPathComponent("download.gz")
        try FileManager.default.copyItem(at: single, to: renamed)
        let out = URL(fileURLWithPath: "/out", isDirectory: true)
        #expect(OutputPlanner.destination(for: renamed, target: .decompressed, in: out) { _ in false }.path == "/out/notes.txt")
    }

    @Test func anyFileCanBeCompressed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).weird")
        try Data([0x00, 0x13, 0x37]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileFormat.detect(at: url) == nil)
        #expect(FileFormat.detectForConversion(at: url) == .other)
        #expect(FileFormat.detectForConversion(at: FileManager.default.temporaryDirectory) == nil)
        let matrix = ConversionMatrix(writable: FileFormat.systemWritable())
        #expect(matrix.targets(for: .other) == [.gz, .bz2, .xz])
        #expect(matrix.targets(for: .gz) == [.decompressed])
    }

    @Test func routes() {
        #expect(ConversionMatrix.canConvert(from: .png, to: .gz))
        #expect(ConversionMatrix.canConvert(from: .epub, to: .xz))
        #expect(ConversionMatrix.canConvert(from: .csv, to: .bz2))
        #expect(!ConversionMatrix.canConvert(from: .zip, to: .gz))
        #expect(!ConversionMatrix.canConvert(from: .gz, to: .xz))
        #expect(!ConversionMatrix.canConvert(from: .png, to: .decompressed))
        #expect(!ConversionMatrix.canConvert(from: .gz, to: .png))
        #expect(ConversionMatrix.canConvert(from: .obj, to: .usdz))
        #expect(ConversionMatrix.canConvert(from: .abc, to: .stl))
        #expect(!ConversionMatrix.canConvert(from: .obj, to: .abc))
        #expect(ConversionMatrix.canConvert(from: .stl, to: .png))
        #expect(!ConversionMatrix.canConvert(from: .stl, to: .jpeg))
        #expect(!ConversionMatrix.canConvert(from: .png, to: .obj))
        #expect(ConversionMatrix.canConvert(from: .sqlite, to: .csv))
        #expect(ConversionMatrix.canConvert(from: .sqlite, to: .sql))
        #expect(!ConversionMatrix.canConvert(from: .sqlite, to: .xlsx))
        #expect(!ConversionMatrix.canConvert(from: .csv, to: .sql))
        #expect(!ConversionMatrix.canConvert(from: .csv, to: .sqlite))
        let matrix = ConversionMatrix(writable: FileFormat.systemWritable())
        #expect(matrix.possibleLosses(from: .obj, to: .usdz) == [.materialsMayNotCarryOver, .separateTexturesNotIncluded])
        #expect(matrix.possibleLosses(from: .sqlite, to: .csv).contains(.onlyLargestTableKept))
        #expect(matrix.possibleLosses(from: .epub, to: .gz).isEmpty)
        #expect(FileFormat.Family.model.timeout == .seconds(300))
    }

    @Test func compressedNamesKeepTheOriginal() {
        let out = URL(fileURLWithPath: "/out", isDirectory: true)
        func name(_ path: String, _ target: FileFormat, taken: Set<String> = []) -> String {
            OutputPlanner.destination(for: URL(fileURLWithPath: path), target: target, in: out) { taken.contains($0.path) }.lastPathComponent
        }
        #expect(name("/in/report.pdf", .gz) == "report.pdf.gz")
        #expect(name("/in/report.pdf", .xz, taken: ["/out/report.pdf.xz"]) == "report 2.pdf.xz")
        #expect(name("/in/Makefile", .bz2) == "Makefile.bz2")
        #expect(name("/in/.env", .gz) == "env.gz")
        #expect(name("/in/report.pdf.gz", .decompressed) == "report.pdf")
        #expect(name("/in/report.pdf.bz2", .decompressed, taken: ["/out/report.pdf"]) == "report 2.pdf")
        #expect(name("/in/README.xz", .decompressed) == "README")
        #expect(name("/in/photos.tar.gz", .zip) == "photos.zip")
    }

    @Test func gzipOriginalNameIsSanitised() {
        func header(_ name: String, extra: Bool = false) -> Data {
            var bytes: [UInt8] = [0x1F, 0x8B, 8, extra ? 0x0C : 0x08, 0, 0, 0, 0, 0, 3]
            if extra { bytes += [2, 0, 0xAA, 0xBB] }
            return Data(bytes + Array(name.utf8) + [0])
        }
        #expect(FileFormat.gzipOriginalName(header("report.pdf")) == "report.pdf")
        #expect(FileFormat.gzipOriginalName(header("report.pdf", extra: true)) == "report.pdf")
        #expect(FileFormat.gzipOriginalName(header("../../etc/passwd")) == "passwd")
        #expect(FileFormat.gzipOriginalName(header(".hidden")) == "hidden")
        #expect(FileFormat.gzipOriginalName(header("")) == nil)
        #expect(FileFormat.gzipOriginalName(Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3, 1])) == nil)
    }
}
