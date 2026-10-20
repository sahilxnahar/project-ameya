import AmeyaCore
import AppKit
import Foundation
import PDFKit
import Testing
@testable import AmeyaEngines

@Suite("Documents")
@MainActor
struct DocumentTests {
    let sample = "Quarterly report\nRevenue grew in every region.\nNext steps: hire, ship, repeat."

    @Test("Text survives every rich-format round trip", arguments: [FileFormat.rtf, .html, .docx, .doc, .odt])
    func roundTrip(through format: FileFormat) throws {
        let (rich, _) = try DocumentConverter.convert(Data(sample.utf8), from: .txt, to: format)
        #expect(FileFormat.detect(header: rich.prefix(64), fileExtension: format.preferredExtension) == format)
        let (plain, notes) = try DocumentConverter.convert(rich, from: format, to: .txt)
        let text = String(decoding: plain, as: UTF8.self)
        #expect(text.contains("Revenue grew in every region."))
        #expect(text.contains("Next steps: hire, ship, repeat."))
        #expect(notes == [.formattingRemoved])
    }

    @Test func htmlTablesAndStylesRenderToPDF() throws {
        let html = """
        <html><body><h1>Invoice</h1><p><b>Bold</b> and <i>italic</i></p>
        <table border="1"><tr><td>Item</td><td>Price</td></tr><tr><td>Tea</td><td>₹40</td></tr></table></body></html>
        """
        let (pdf, _) = try DocumentConverter.convert(Data(html.utf8), from: .html, to: .pdf)
        let document = try #require(PDFDocument(data: pdf))
        #expect(document.pageCount == 1)
        let text = document.string ?? ""
        #expect(text.contains("Invoice"))
        #expect(text.contains("Tea"))
        #expect(text.contains("₹40"))
    }

    @Test func longTextFlowsOntoMorePages() throws {
        let long = (1...400).map { "Line \($0) of a long document." }.joined(separator: "\n")
        let (pdf, _) = try DocumentConverter.convert(Data(long.utf8), from: .txt, to: .pdf)
        let document = try #require(PDFDocument(data: pdf))
        #expect(document.pageCount > 3)
        #expect(document.page(at: document.pageCount - 1)?.string?.contains("Line 400") == true)
    }

    @Test func pdfTextIsExtracted() throws {
        let (pdf, _) = try DocumentConverter.convert(Data(sample.utf8), from: .txt, to: .pdf)
        let (docx, notes) = try DocumentConverter.convert(pdf, from: .pdf, to: .docx)
        #expect(notes == [.onlyTextKept])
        let (plain, _) = try DocumentConverter.convert(docx, from: .docx, to: .txt)
        #expect(String(decoding: plain, as: UTF8.self).contains("Revenue grew"))
    }

    @Test func imageOnlyPDFsSayThereIsNoText() throws {
        let png = try Fixtures.encode([Fixtures.halfTransparent()], as: .png)
        let (pdf, _) = try ImageConverter.convert(png, request: ConversionRequest(target: .pdf))
        #expect(throws: ConversionError.noText) {
            try DocumentConverter.convert(pdf, from: .pdf, to: .txt)
        }
    }

    @Test func legacyEncodingsAreDetected() {
        // "café — naïve" in Windows-1252
        let bytes = Data([0x63, 0x61, 0x66, 0xE9, 0x20, 0x97, 0x20, 0x6E, 0x61, 0xEF, 0x76, 0x65])
        #expect(DocumentConverter.decodeText(bytes) == "café — naïve")
        #expect(DocumentConverter.decodeText(Data("plain ascii".utf8)) == "plain ascii")
    }

    @Test func garbageIsRejected() {
        #expect(throws: ConversionError.unreadable) {
            try DocumentConverter.convert(Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 0]), from: .docx, to: .txt)
        }
    }
}

@Suite("Subtitles")
struct SubtitleTests {
    let srt = """
    1
    00:00:01,000 --> 00:00:02,500
    Hello there

    2
    01:02:03,040 --> 01:02:04,000
    <i>Second</i> line
    with a break

    """

    @Test func srtToVttAndBackIsLossless() throws {
        let (vtt, vttNotes) = try SubtitleConverter.convert(Data(srt.utf8), from: .srt, to: .vtt)
        let vttText = String(decoding: vtt, as: UTF8.self)
        #expect(vttText.hasPrefix("WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHello there"))
        #expect(vttNotes.isEmpty)

        let (back, _) = try SubtitleConverter.convert(vtt, from: .vtt, to: .srt)
        let (original, _) = SubtitleConverter.parse(srt)
        let (roundTripped, _) = SubtitleConverter.parse(String(decoding: back, as: UTF8.self))
        #expect(roundTripped == original)
        #expect(original[1].start == 3_723_040)
        #expect(original[1].text == "<i>Second</i> line\nwith a break")
    }

    @Test func vttStylingIsDroppedWithANote() throws {
        let vtt = "WEBVTT\n\nNOTE written by hand\n\nintro\n00:05.250 --> 00:07.000 align:start position:10%\n<v Narrator><c.loud>Short</c> timestamps</v>\n"
        let (srtData, notes) = try SubtitleConverter.convert(Data(vtt.utf8), from: .vtt, to: .srt)
        #expect(notes == [.subtitleStylingRemoved])
        #expect(String(decoding: srtData, as: UTF8.self) == "1\n00:00:05,250 --> 00:00:07,000\nShort timestamps\n")
    }

    @Test func windowsLineEndingsAndMissingNumbersAreFine() throws {
        let messy = "00:00:01,5 --> 00:00:02,25\r\nNo index\r\n\r\n"
        let (cues, _) = SubtitleConverter.parse(messy)
        #expect(cues == [SubtitleConverter.Cue(start: 1_500, end: 2_250, text: "No index")])
    }

    @Test func filesWithoutCuesAreRejected() {
        #expect(throws: ConversionError.noSubtitles) {
            try SubtitleConverter.convert(Data("just some words".utf8), from: .srt, to: .vtt)
        }
    }
}

@Suite("Engine routing")
@MainActor
struct EngineRoutingTests {
    @Test func refusesConversionsWithNoEngine() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let input = scratch.appendingPathComponent("input.txt")
        try Data("hello".utf8).write(to: input)
        await #expect(throws: ConversionError.unsupportedConversion(from: .txt, to: .mp4)) {
            _ = try await Engine.convert(input: input, request: ConversionRequest(source: .txt, target: .mp4), scratch: scratch) { _ in }
        }
    }
}
