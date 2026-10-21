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

    @Test func subtitleFormatsAreDetectedByContent() {
        func detect(_ text: String, _ ext: String) -> FileFormat? {
            FileFormat.detect(header: Data(text.utf8), fileExtension: ext)
        }
        #expect(detect("[Script Info]\nScriptType: v4.00+\n", "txt") == .ass)
        #expect(detect("\u{FEFF}[Script Info]\r\nScriptType: v4.00\r\n", "") == .ssa)
        #expect(detect("[Script Info]\n; no script type\n", "ssa") == .ssa)
        #expect(detect("[Script Info]\n; no script type\n", "") == .ass)
        #expect(detect("<?xml version=\"1.0\"?>\n<tt xmlns=\"http://www.w3.org/ns/ttml\">", "xml") == .ttml)
        #expect(detect("<tt:tt xmlns:tt=\"http://www.w3.org/ns/ttml\">", "") == .ttml)
        #expect(detect("<tt xmlns=\"http://www.w3.org/2006/10/ttaf1\">", "dfxp") == .ttml)
        #expect(detect("<?xml version=\"1.0\"?><root/>", "xml") == .xml) // plain XML belongs to the data engine
        #expect(detect("<SAMI>\n<HEAD>", "") == .sami)
        #expect(detect("0:00:01.000,0:00:02.500\nHi\n", "sbv") == .sbv)
        #expect(detect("0:00:01.000,0:00:02.500\nHi\n", "") == .sbv)
        #expect(detect("0:00:01.000,0:00:02.500\nHi\n", "txt") == .txt)
        #expect(detect("{1}{1}23.976\n{10}{20}Hi\n", "sub") == .microDVD)
        #expect(detect("[ti:Song]\n[00:01.00]Hi\n", "lrc") == .lrc)
        #expect(detect("[00:01.00]Hi\n", "") == .lrc)
        #expect(detect("[section]\nkey=value\n", "") == nil)
        // .sub is also VobSub: binary MPEG-PS packets, which Ameya can't read.
        #expect(FileFormat.detect(header: Data([0x00, 0x00, 0x01, 0xBA, 0x44, 0x00]), fileExtension: "sub") == nil)
        #expect(FileFormat.fromExtension("dfxp") == .ttml)
        #expect(FileFormat.fromExtension("smi") == .sami)
    }

    @Test func subtitleLosses() {
        let matrix = ConversionMatrix(writable: [])
        #expect(matrix.possibleLosses(from: .srt, to: .ass).isEmpty)
        #expect(matrix.possibleLosses(from: .ass, to: .ssa).isEmpty)
        #expect(matrix.possibleLosses(from: .ass, to: .srt) == [.subtitleStylingRemoved])
        #expect(matrix.possibleLosses(from: .srt, to: .lrc) == [.subtitleStylingRemoved, .subtitleEndTimesDropped])
        #expect(matrix.possibleLosses(from: .srt, to: .microDVD) == [.subtitleFrameRateAssumed])
        #expect(ConversionMatrix.canConvert(from: .sami, to: .ttml))
    }

    @Test func extensionFallback() {
        #expect(FileFormat.fromExtension("JPEG") == .jpeg)
        #expect(FileFormat.fromExtension("tif") == .tiff)
        #expect(FileFormat.fromExtension("xyz") == nil)
    }
}
