import Foundation
import Testing
@testable import AmeyaCore

@Suite("Format detection")
struct FormatDetectionTests {
    @Test("Magic bytes identify each format", arguments: [
        ([0xFF, 0xD8, 0xFF, 0xE0], FileFormat.jpeg),
        ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], .png),
        (Array("GIF89a".utf8), .gif),
        (Array("%PDF-1.7".utf8), .pdf),
        ([0x49, 0x49, 0x2A, 0x00], .tiff),
        ([0x4D, 0x4D, 0x00, 0x2A], .tiff),
        (Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8), .webp),
        (Array("BM".utf8) + [UInt8](repeating: 0, count: 12), .bmp),
        ([0, 0, 0, 0x18] + Array("ftypheic".utf8), .heic),
        ([0, 0, 0, 0x18] + Array("ftypmif1".utf8), .heic),
        ([0, 0, 0, 0x1C] + Array("ftypavif".utf8), .avif),
        (Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8), .wav),
        (Array("FORM".utf8) + [0, 0, 0, 0] + Array("AIFF".utf8), .aiff),
        (Array("fLaC".utf8), .flac),
        (Array("caff".utf8), .caf),
        (Array("ID3".utf8) + [4, 0], .mp3),
        ([0xFF, 0xFB, 0x90, 0x64], .mp3),
        ([0, 0, 0, 0x20] + Array("ftypM4A ".utf8), .m4a),
        ([0, 0, 0, 0x14] + Array("ftypqt  ".utf8), .mov),
        ([0, 0, 0, 0x20] + Array("ftypisom".utf8), .mp4),
        ([0, 0, 0, 0x20] + Array("ftypM4V ".utf8), .m4v),
        (Array("{\\rtf1\\ansi".utf8), .rtf),
        (Array("WEBVTT\n\n".utf8), .vtt),
        ([0xEF, 0xBB, 0xBF] + Array("WEBVTT".utf8), .vtt),
        (Array("  <!DOCTYPE html><html>".utf8), .html),
    ] as [([UInt8], FileFormat)])
    func sniff(bytes: [UInt8], expected: FileFormat) {
        #expect(FileFormat.sniff(Data(bytes)) == expected)
    }

    @Test func unknownBytesAreNotGuessed() {
        #expect(FileFormat.sniff(Data("hello world".utf8)) == nil)
        #expect(FileFormat.sniff(Data()) == nil)
        #expect(FileFormat.sniff(Data([0, 0, 0, 0x18] + Array("ftypxxxx".utf8))) == nil)
        #expect(FileFormat.sniff(Data("BM".utf8)) == nil) // too short to be a real BMP
    }

    @Test func contentsWinOverExtension() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileFormat.detect(at: url) == .png)
    }

    @Test func adtsAACIsNotMistakenForMP3() {
        #expect(FileFormat.sniff(Data([0xFF, 0xF1, 0x50, 0x80])) == nil)
    }

    @Test func containersNeedTheExtensionToBreakTies() {
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00])
        #expect(FileFormat.detect(header: zip, fileExtension: "docx") == .docx)
        #expect(FileFormat.detect(header: zip, fileExtension: "odt") == .odt)
        #expect(FileFormat.detect(header: zip, fileExtension: "zip") == .zip)
        #expect(FileFormat.detect(header: zip, fileExtension: "") == .zip)
        #expect(FileFormat.detect(header: zip, fileExtension: "xlsx") == nil)
        #expect(FileFormat.detect(header: zip, fileExtension: "epub") == .epub)
        let ole = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        #expect(FileFormat.detect(header: ole, fileExtension: "doc") == .doc)
        #expect(FileFormat.detect(header: ole, fileExtension: "xls") == nil)
        let mp4 = Data([0, 0, 0, 0x20] + Array("ftypisom".utf8))
        #expect(FileFormat.detect(header: mp4, fileExtension: "m4a") == .m4a)
        #expect(FileFormat.detect(header: mp4, fileExtension: "jpg") == .mp4)
    }

    @Test func textFormatsComeFromTheExtensionWhenTheBytesAreText() {
        let srt = Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n".utf8)
        #expect(FileFormat.detect(header: srt, fileExtension: "srt") == .srt)
        #expect(FileFormat.detect(header: srt, fileExtension: "txt") == .txt)
        #expect(FileFormat.detect(header: Data([0x00, 0x01, 0x02]), fileExtension: "txt") == nil)
    }

    @Test func dataFormats() {
        let xmlPlist = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"x\">\n<plist version=\"1.0\"><dict/></plist>".utf8)
        #expect(FileFormat.sniff(xmlPlist) == .plist)
        #expect(FileFormat.sniff(Data("bplist00".utf8) + Data(count: 8)) == .plist)
        #expect(FileFormat.sniff(Data("<?xml version=\"1.0\"?><rss/>".utf8)) == .xml)
        #expect(FileFormat.sniff(Data("<?xml version=\"1.0\"?>\n<!DOCTYPE html><html/>".utf8)) == .html)
        // Contents decide even when the extension disagrees.
        #expect(FileFormat.detect(header: xmlPlist, fileExtension: "xml") == .plist)

        let text = Data("a,b\n1,2\n".utf8)
        #expect(FileFormat.detect(header: text, fileExtension: "csv") == .csv)
        #expect(FileFormat.detect(header: text, fileExtension: "tsv") == .tsv)
        #expect(FileFormat.detect(header: Data("{\"a\": 1}".utf8), fileExtension: "json") == .json)
        #expect(FileFormat.detect(header: Data("<a/>".utf8), fileExtension: "xml") == .xml)
        #expect(FileFormat.detect(header: Data("{a = 1;}".utf8), fileExtension: "plist") == .plist) // old-style text plist
        #expect(FileFormat.detect(header: Data([0x00, 0x01]), fileExtension: "csv") == nil)
        // Only written, so never offered as a source.
        #expect(FileFormat.detect(header: Data("a: 1\n".utf8), fileExtension: "yaml") == nil)
        #expect(FileFormat.sniff(Data("{\"a\": 1}".utf8)) == nil)
    }

    @Test func booksAndComicsAreRecognised() {
        // An EPUB is known by its stored `mimetype` entry, whatever the file is called.
        var epub = Data([0x50, 0x4B, 0x03, 0x04, 0x0A, 0x00] + [UInt8](repeating: 0, count: 20))
        epub.append(contentsOf: [8, 0, 0, 0]) // name length 8, no extra field
        epub.append(Data("mimetypeapplication/epub+zip".utf8))
        #expect(epub.count == 58)
        #expect(FileFormat.detect(header: epub, fileExtension: "zip") == .epub)
        #expect(FileFormat.detect(header: epub, fileExtension: "") == .epub)
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00])
        #expect(FileFormat.detect(header: zip, fileExtension: "cbz") == .cbz)
        #expect(FileFormat.detect(header: zip, fileExtension: "CBR") == .cbr) // many CBRs are ZIPs
        let rar = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])
        #expect(FileFormat.detect(header: rar, fileExtension: "cbr") == .cbr)
        #expect(FileFormat.detect(header: rar, fileExtension: "rar") == .rar)
        #expect(FileFormat.detect(header: Data("plain text".utf8), fileExtension: "cbz") == nil)
        #expect(FileFormat.fromExtension("epub") == .epub)
        #expect(FileFormat.epub.family == .document && FileFormat.cbz.family == .document)
    }

    @Test func extensionFallback() {
        #expect(FileFormat.fromExtension("JPEG") == .jpeg)
        #expect(FileFormat.fromExtension("tif") == .tiff)
        #expect(FileFormat.fromExtension("xyz") == nil)
    }
}

@Suite("Output naming")
struct OutputPlannerTests {
    let directory = URL(fileURLWithPath: "/out", isDirectory: true)

    @Test func swapsExtension() {
        let url = OutputPlanner.destination(for: URL(fileURLWithPath: "/in/photo.png"), target: .jpeg, in: directory) { _ in false }
        #expect(url.path == "/out/photo.jpg")
    }

    @Test func neverReusesATakenName() {
        let taken: Set<String> = ["/out/photo.jpg", "/out/photo 2.jpg"]
        let url = OutputPlanner.destination(for: URL(fileURLWithPath: "/in/photo.png"), target: .jpeg, in: directory) {
            taken.contains($0.path)
        }
        #expect(url.path == "/out/photo 3.jpg")
    }

    @Test func sameNameAsSourceIsTaken() {
        // Converting /out/a.jpg to JPEG-in-the-same-folder would collide with the original.
        let source = URL(fileURLWithPath: "/out/a.jpg")
        let url = OutputPlanner.destination(for: source, target: .jpeg, in: directory) { $0 == source }
        #expect(url.path == "/out/a 2.jpg")
    }

    @Test func keepsInnerDotsAndStripsLeadingDots() {
        #expect(OutputPlanner.baseName(of: URL(fileURLWithPath: "/in/v1.2.final.png")) == "v1.2.final")
        #expect(OutputPlanner.baseName(of: URL(fileURLWithPath: "/in/.hidden.png")) == "hidden")
        // ".png" is a hidden file named "png" with no extension.
        #expect(OutputPlanner.baseName(of: URL(fileURLWithPath: "/in/.png")) == "png")
        #expect(OutputPlanner.baseName(of: URL(fileURLWithPath: "/in/...")) == "Converted")
    }
}

@Suite("Conversion matrix")
struct ConversionMatrixTests {
    let matrix = ConversionMatrix(writable: [.jpeg, .png, .tiff, .gif, .pdf, .heic])

    @Test func neverOffersTheSourceOrUnwritableFormats() {
        let targets = matrix.targets(for: .png)
        #expect(!targets.contains(.png))
        #expect(!targets.contains(.webp))
        #expect(targets.contains(.jpeg))
    }

    @Test func commonTargetsAreTheIntersection() {
        let common = matrix.commonTargets(for: [.png, .jpeg])
        #expect(!common.contains(.png))
        #expect(!common.contains(.jpeg))
        #expect(common.contains(.pdf))
        #expect(matrix.commonTargets(for: []).isEmpty)
    }

    @Test func warnsBeforeLosingThings() {
        #expect(matrix.possibleLosses(from: .png, to: .jpeg).contains(.transparencyFilledWhite))
        #expect(matrix.possibleLosses(from: .gif, to: .jpeg).contains(.onlyFirstFrameKept))
        #expect(matrix.possibleLosses(from: .gif, to: .pdf) == [.animationBecamePages])
        #expect(matrix.possibleLosses(from: .pdf, to: .png).contains(.onlyFirstPageKept))
        #expect(matrix.possibleLosses(from: .jpeg, to: .png).isEmpty)
    }

    @Test func routesBetweenFamilies() {
        #expect(ConversionMatrix.canConvert(from: .pdf, to: .docx))
        #expect(ConversionMatrix.canConvert(from: .docx, to: .pdf))
        #expect(!ConversionMatrix.canConvert(from: .docx, to: .png))
        #expect(ConversionMatrix.canConvert(from: .mp4, to: .m4a))
        #expect(ConversionMatrix.canConvert(from: .mp4, to: .gif))
        #expect(ConversionMatrix.canConvert(from: .gif, to: .mp4))
        #expect(!ConversionMatrix.canConvert(from: .png, to: .mp4))
        #expect(!ConversionMatrix.canConvert(from: .m4a, to: .mp4))
        #expect(ConversionMatrix.canConvert(from: .srt, to: .vtt))
        #expect(!ConversionMatrix.canConvert(from: .srt, to: .txt))
    }

    @Test func routesBooksAndComics() {
        for target in [FileFormat.pdf, .html, .md, .txt, .docx, .rtf, .odt] {
            #expect(ConversionMatrix.canConvert(from: .epub, to: target))
        }
        for source in [FileFormat.md, .html, .docx, .rtf, .odt, .txt] {
            #expect(ConversionMatrix.canConvert(from: source, to: .epub))
        }
        #expect(ConversionMatrix.canConvert(from: .cbz, to: .pdf))
        #expect(ConversionMatrix.canConvert(from: .cbr, to: .pdf))
        #expect(ConversionMatrix.canConvert(from: .cbr, to: .cbz))
        #expect(ConversionMatrix.canConvert(from: .pdf, to: .cbz))
        #expect(!ConversionMatrix.canConvert(from: .cbz, to: .cbr))
        #expect(!ConversionMatrix.canConvert(from: .cbz, to: .txt))
        #expect(!ConversionMatrix.canConvert(from: .png, to: .cbz))
        #expect(!ConversionMatrix.canConvert(from: .pdf, to: .epub))
        #expect(!ConversionMatrix.canConvert(from: .epub, to: .cbz))
        #expect(!ConversionMatrix.canConvert(from: .epub, to: .png))
        #expect(!ConversionMatrix.canConvert(from: .zip, to: .epub))

        let system = ConversionMatrix(writable: FileFormat.systemWritable())
        #expect(!FileFormat.systemWritable().contains(.cbr))
        #expect(system.targets(for: .pdf).contains(.cbz))
        #expect(system.targets(for: .md).contains(.epub))
        #expect(system.targets(for: .cbr) == [.pdf, .cbz, .gz, .bz2, .xz])
        #expect(system.possibleLosses(from: .epub, to: .pdf) == [.bookLayoutReflowed])
        #expect(system.possibleLosses(from: .epub, to: .txt) == [.formattingRemoved])
        #expect(system.possibleLosses(from: .md, to: .epub).isEmpty)
        #expect(system.possibleLosses(from: .pdf, to: .cbz) == [.pagesBecamePictures])
    }

    @Test func neverOffersFormatsThisMacCantWrite() {
        let system = ConversionMatrix(writable: FileFormat.systemWritable())
        #expect(!system.targets(for: .wav).contains(.mp3))
        #expect(!system.targets(for: .wav).contains(.wav))
        #expect(system.targets(for: .wav).contains(.flac))
    }

    @Test func warnsAboutMediaAndDocumentLosses() {
        #expect(matrix.possibleLosses(from: .pdf, to: .docx) == [.onlyTextKept])
        #expect(matrix.possibleLosses(from: .docx, to: .txt) == [.formattingRemoved])
        #expect(matrix.possibleLosses(from: .mov, to: .wav) == [.onlySoundKept])
        #expect(matrix.possibleLosses(from: .wav, to: .m4a) == [.lossyAudio])
        #expect(matrix.possibleLosses(from: .wav, to: .flac).isEmpty)
        #expect(matrix.possibleLosses(from: .vtt, to: .srt) == [.subtitleStylingRemoved])
    }

    @Test func routesDataFormats() {
        let system = ConversionMatrix(writable: FileFormat.systemWritable())
        #expect(system.targets(for: .csv) == [.html, .md, .tsv, .json, .plist, .xml, .yaml, .xlsx, .gz, .bz2, .xz])
        #expect(system.targets(for: .xml).contains(.json))
        #expect(system.targets(for: .plist).contains(.json))
        #expect(system.targets(for: .yaml).isEmpty)
        #expect(system.targets(for: .xlsx).isEmpty)
        #expect(!ConversionMatrix.canConvert(from: .json, to: .pdf))
        #expect(!ConversionMatrix.canConvert(from: .html, to: .csv))
        #expect(!ConversionMatrix.canConvert(from: .json, to: .json))
    }

    @Test func warnsAboutDataLosses() {
        #expect(matrix.possibleLosses(from: .json, to: .csv) == [.nestedDataFlattened])
        #expect(matrix.possibleLosses(from: .csv, to: .json) == [.tableValuesTyped])
        #expect(matrix.possibleLosses(from: .csv, to: .xlsx).isEmpty)
        #expect(matrix.possibleLosses(from: .xml, to: .json) == [.xmlStructureMapped])
        #expect(matrix.possibleLosses(from: .json, to: .plist) == [.nullsRemoved])
        #expect(matrix.possibleLosses(from: .plist, to: .yaml) == [.datesAndDataAsText])
    }

    @Test func requestRoundTripsThroughTheWorkerProtocol() throws {
        let request = ConversionRequest(target: .heic, options: ConversionOptions(quality: 0.7))
        #expect(try WorkerProtocol.decodeRequest(WorkerProtocol.encode(request)) == request)
    }
}

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
        #expect(FileFormat.detect(at: tarball) == .tgz) // contents win over the ".gz" name
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
