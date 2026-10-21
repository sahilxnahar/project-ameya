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
        #expect(FileFormat.detect(header: zip, fileExtension: "epub") == nil)
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

    @Test func neverOffersFormatsThisMacCantWrite() {
        let system = ConversionMatrix(writable: FileFormat.systemWritable())
        // MP3 needs the bundled FFmpeg helper (LAME); plain `swift test` runs have none unless AMEYA_FFMPEG is set.
        #expect(system.targets(for: .wav).contains(.mp3) == FFmpegAvailability.isAvailable)
        #expect(!system.targets(for: .mp4).contains(.flv)) // read-only
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

    @Test func requestRoundTripsThroughTheWorkerProtocol() throws {
        let request = ConversionRequest(target: .heic, options: ConversionOptions(quality: 0.7))
        #expect(try WorkerProtocol.decodeRequest(WorkerProtocol.encode(request)) == request)
    }
}

@Suite("FFmpeg formats")
struct FFmpegFormatTests {
    static func ogg(_ codecHeader: String) -> [UInt8] {
        Array("OggS".utf8) + [0, 2] + [UInt8](repeating: 0, count: 22) + Array(codecHeader.utf8)
    }

    static func ebml(_ docType: String) -> [UInt8] {
        [0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81, 0x01, 0x42, 0xF7, 0x81, 0x01,
         0x42, 0x82, 0x80 | UInt8(docType.utf8.count)] + Array(docType.utf8)
    }

    static func transportStream(prefix: Int) -> [UInt8] {
        let stride = 188 + prefix
        var bytes = [UInt8](repeating: 0xFF, count: 3 * stride + 1)
        for packet in 0..<3 { bytes[packet * stride + prefix] = 0x47 }
        return bytes
    }

    @Test("Magic bytes identify each FFmpeg format", arguments: [
        (FFmpegFormatTests.ogg("OpusHead"), FileFormat.opus),
        (FFmpegFormatTests.ogg("\u{01}vorbis"), .ogg),
        (FFmpegFormatTests.ebml("webm"), .webm),
        (FFmpegFormatTests.ebml("matroska"), .mkv),
        (Array("RIFF".utf8) + [0, 0, 0, 0] + Array("AVI LIST".utf8), .avi),
        (Array("FLV".utf8) + [1, 5, 0, 0, 0, 9], .flv),
        ([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C], .wmv),
        (FFmpegFormatTests.transportStream(prefix: 0), .ts),
        (FFmpegFormatTests.transportStream(prefix: 4), .ts),
        ([0x00, 0x00, 0x01, 0xBA, 0x44, 0x00], .mpg),
        ([0, 0, 0, 0x14] + Array("ftyp3gp4".utf8), .threegp),
        ([0, 0, 0, 0x14] + Array("ftyp3g2a".utf8), .threegp),
    ] as [([UInt8], FileFormat)])
    func sniff(bytes: [UInt8], expected: FileFormat) {
        #expect(FileFormat.sniff(Data(bytes)) == expected)
    }

    @Test func oneSyncByteIsNotATransportStream() {
        var bytes = FFmpegFormatTests.transportStream(prefix: 0)
        bytes[188] = 0
        #expect(FileFormat.sniff(Data(bytes)) == nil)
    }

    @Test func extensionsMapToTheNewFormats() {
        #expect(FileFormat.fromExtension("oga") == .ogg)
        #expect(FileFormat.fromExtension("m2ts") == .ts)
        #expect(FileFormat.fromExtension("mpeg") == .mpg)
        #expect(FileFormat.fromExtension("3gp") == .threegp)
        #expect(FileFormat.threegp.rawValue == "3gp")
    }

    @Test func routesNeedTheHelper() {
        for (source, target) in [(FileFormat.wav, FileFormat.mp3), (.mkv, .mp4), (.mp4, .webm), (.ogg, .wav),
                                 (.mp4, .opus), (.flv, .mkv), (.wmv, .m4a), (.avi, .ogg)] {
            #expect(ConversionMatrix.canConvert(from: source, to: target, ffmpeg: true), "\(source) -> \(target)")
            #expect(!ConversionMatrix.canConvert(from: source, to: target, ffmpeg: false), "\(source) -> \(target)")
        }
        // AVFoundation keeps everything it already handled.
        #expect(ConversionMatrix.canConvert(from: .mp3, to: .wav, ffmpeg: false))
        #expect(ConversionMatrix.canConvert(from: .threegp, to: .mp4, ffmpeg: false))
        // Read-only formats are never targets; FFmpeg sources don't go through the GIF paths.
        #expect(!ConversionMatrix.canConvert(from: .mp4, to: .flv, ffmpeg: true))
        #expect(!ConversionMatrix.canConvert(from: .mkv, to: .gif, ffmpeg: true))
        #expect(!ConversionMatrix.canConvert(from: .gif, to: .webm, ffmpeg: true))
        #expect(!ConversionMatrix.canConvert(from: .ogg, to: .mp4, ffmpeg: true))
    }

    @Test func writableOnlyWithTheHelper() {
        let writable = FileFormat.systemWritable()
        for format in [FileFormat.mp3, .ogg, .opus, .mkv, .webm, .avi] {
            #expect(writable.contains(format) == FFmpegAvailability.isAvailable)
        }
        for format in [FileFormat.flv, .wmv, .ts, .mpg, .threegp] {
            #expect(!writable.contains(format))
        }
    }
}
