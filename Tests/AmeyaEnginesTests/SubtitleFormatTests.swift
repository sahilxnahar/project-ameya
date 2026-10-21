import AmeyaCore
import Foundation
import Testing
@testable import AmeyaEngines

@Suite("Subtitle formats")
struct SubtitleFormatTests {
    typealias Cue = SubtitleConverter.Cue

    static let formats: [FileFormat] = [.srt, .vtt, .ass, .ssa, .sbv, .ttml, .lrc, .microDVD, .sami]

    /// One sample cue and what survives formats that style whole lines only, or not at all.
    struct Sample {
        var start: Int
        var end: Int
        var text: String
        var lineStyled: String
        var plain: String
    }

    static let samples = [
        Sample(start: 1_000, end: 2_500, text: "Hello there", lineStyled: "Hello there", plain: "Hello there"),
        Sample(start: 3_723_040, end: 3_724_000, text: "<i>Second</i> line\nwith a break",
               lineStyled: "Second line\nwith a break", plain: "Second line\nwith a break"),
        Sample(start: 3_730_000, end: 3_732_500, text: "Ünïcödé — 日本語 ✓ & <b>bold</b>, \"quoted\"",
               lineStyled: "Ünïcödé — 日本語 ✓ & bold, \"quoted\"", plain: "Ünïcödé — 日本語 ✓ & bold, \"quoted\""),
        Sample(start: 3_740_000, end: 3_741_000, text: "<i>Both lines\nin italics</i>",
               lineStyled: "<i>Both lines\nin italics</i>", plain: "Both lines\nin italics"),
    ]

    static var sampleSRT: String {
        SubtitleConverter.renderSRT(samples.map { Cue(start: $0.start, end: $0.end, text: $0.text) })
    }

    static func convert(_ text: String, from source: FileFormat, to target: FileFormat,
                        options: ConversionOptions = ConversionOptions()) throws -> (String, [ConversionNote]) {
        let (data, notes) = try SubtitleConverter.convert(Data(text.utf8), from: source, to: target, options: options)
        return (String(decoding: data, as: UTF8.self), notes)
    }

    @Test("Every pair keeps timings, text and the styling both formats can hold", arguments: formats)
    func roundTrip(via middle: FileFormat) throws {
        let first = middle == .srt ? Self.sampleSRT : try Self.convert(Self.sampleSRT, from: .srt, to: middle).0
        #expect(FileFormat.detect(header: Data(first.utf8), fileExtension: middle.preferredExtension) == middle)
        for target in Self.formats {
            let second = target == middle ? first : try Self.convert(first, from: middle, to: target).0
            let back = target == .srt ? second : try Self.convert(second, from: target, to: .srt).0
            let (cues, _) = SubtitleConverter.parse(back)
            let path = "srt → \(middle.rawValue) → \(target.rawValue)"
            try #require(cues.count == Self.samples.count, "\(path): \(cues)")
            let formats: Set<FileFormat> = [middle, target]
            let tolerance = formats.contains(.microDVD) ? 50 : 0
            for (cue, sample) in zip(cues, Self.samples) {
                let expected = !formats.isDisjoint(with: [.sbv, .lrc]) ? sample.plain
                    : formats.contains(.microDVD) ? sample.lineStyled : sample.text
                #expect(SubtitleConverter.canonical(cue.text) == SubtitleConverter.canonical(expected), "\(path)")
                #expect(abs(cue.start - sample.start) <= tolerance, "\(path): start \(cue.start) vs \(sample.start)")
                if !formats.contains(.lrc) {
                    #expect(abs(cue.end - sample.end) <= tolerance, "\(path): end \(cue.end) vs \(sample.end)")
                }
            }
        }
    }

    @Test("Malformed input has no subtitles", arguments: formats)
    func malformed(source: FileFormat) {
        for junk in ["just some words", "", "[Script Info]\nTitle: x", "<tt><body><p>unfinished", "{x}{y}nope"] {
            #expect(throws: ConversionError.noSubtitles) {
                try SubtitleConverter.convert(Data(junk.utf8), from: source, to: source == .srt ? .vtt : .srt)
            }
        }
    }

    // MARK: ASS / SSA

    @Test func assFollowsTheFormatLineAndKeepsCommasInText() throws {
        let ass = """
        [Script Info]
        ScriptType: v4.00+

        [V4+ Styles]
        Format: Name, Fontname, Fontsize
        Style: Default,Arial,20

        [Events]
        Format: Start, End, Style, Name, Layer, MarginL, MarginR, MarginV, Effect, Text
        Comment: 0:00:00.00,0:00:01.00,Default,,0,0,0,0,,not shown
        Dialogue: 0:00:01.00,0:00:02.50,Default,,0,0,0,0,,Hello, world, {\\i1}again{\\i0}\\Nnext {\\pos(10,20)\\c&H00FF00&}line\\hend
        Dialogue: 1:02:03.04,1:02:04.00,Default,,0,0,0,0,,{\\b1\\i1}Both{\\r} plain {Just a comment}too
        """
        let parsed = ASSFormat.parse(ass)
        #expect(parsed.cues == [
            Cue(start: 1_000, end: 2_500, text: "Hello, world, <i>again</i>\nnext line end"),
            Cue(start: 3_723_040, end: 3_724_000, text: "<b><i>Both</i></b> plain too"),
        ])
        #expect(parsed.notes == [.subtitleStylingRemoved])
    }

    @Test func ssaWithoutAFormatLineUsesTheDefaultOrder() throws {
        let ssa = "[Script Info]\nScriptType: v4.00\n\n[Events]\nDialogue: Marked=0,0:00:05.10,0:00:06.00,Default,,0000,0000,0000,,Hi, there\n"
        #expect(ASSFormat.parse(ssa).cues == [Cue(start: 5_100, end: 6_000, text: "Hi, there")])
        let (written, _) = try Self.convert(Self.sampleSRT, from: .srt, to: .ssa)
        #expect(written.contains("[V4 Styles]"))
        #expect(written.contains("Dialogue: Marked=0,1:02:03.04,1:02:04.00,Default,,0,0,0,,{\\i1}Second{\\i0} line\\Nwith a break"))
        let (assText, _) = try Self.convert(Self.sampleSRT, from: .srt, to: .ass)
        #expect(assText.contains("PlayResX: 1920\nPlayResY: 1080"))
        #expect(assText.contains("Style: Default,"))
    }

    // MARK: SBV

    @Test func sbvTimingLines() throws {
        let sbv = "0:00:01.000,0:00:02.500\nHello\nWorld\n\n1:02:03.040,1:02:04.000\nLate\n"
        #expect(SBVFormat.parse(sbv).cues == [
            Cue(start: 1_000, end: 2_500, text: "Hello\nWorld"), Cue(start: 3_723_040, end: 3_724_000, text: "Late"),
        ])
        let (written, notes) = try Self.convert(Self.sampleSRT, from: .srt, to: .sbv)
        #expect(written.hasPrefix("0:00:01.000,0:00:02.500\nHello there\n\n1:02:03.040,1:02:04.000\nSecond line\n"))
        #expect(notes == [.subtitleStylingRemoved])
    }

    // MARK: TTML

    @Test func ttmlClockFramesTicksAndOffsets() throws {
        let ttml = """
        <?xml version="1.0" encoding="utf-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttp="http://www.w3.org/ns/ttml#parameter"
            xmlns:tts="http://www.w3.org/ns/ttml#styling" ttp:frameRate="25" ttp:tickRate="10000000" xml:lang="en">
          <head><styling><style xml:id="it" tts:fontStyle="italic"/></styling></head>
          <body><div begin="10s">
            <p begin="00:00:01:12" end="00:00:02.000">Frames
               <br/>second   line</p>
            <p begin="20000000t" dur="500ms"><span style="it">ticks</span> and offset</p>
            <p begin="1.5m" end="95s" region="bottom">Minutes &amp; <span tts:fontWeight="bold">more</span></p>
          </div></body>
        </tt>
        """
        let parsed = TTMLFormat.parse(Data(ttml.utf8))
        #expect(parsed.cues == [
            Cue(start: 11_480, end: 12_000, text: "Frames\nsecond line"),
            Cue(start: 12_000, end: 12_500, text: "<i>ticks</i> and offset"),
            Cue(start: 100_000, end: 105_000, text: "Minutes & <b>more</b>"),
        ])
        #expect(parsed.notes == [.subtitleStylingRemoved])
    }

    @Test func ttmlFrameRateMultiplierAndDFXPNamespace() {
        let dfxp = """
        <tt xmlns="http://www.w3.org/2006/10/ttaf1" xmlns:ttp="http://www.w3.org/2006/10/ttaf1#parameter"
            ttp:frameRate="30" ttp:frameRateMultiplier="1000 1001"><body><div>
        <p begin="30f" end="01:00:00:00">One</p></div></body></tt>
        """
        let cues = TTMLFormat.parse(Data(dfxp.utf8)).cues
        #expect(cues == [Cue(start: 1_001, end: 3_600_000, text: "One")])
    }

    @Test func ttmlIsEscapedAndWellFormed() throws {
        let (written, notes) = try Self.convert(Self.sampleSRT, from: .srt, to: .ttml)
        #expect(notes.isEmpty)
        #expect(written.contains(#"xml:lang="und""#))
        #expect(written.contains(#"<span tts:fontStyle="italic">Second</span> line<br/>with a break"#))
        #expect(written.contains("&amp; <span tts:fontWeight=\"bold\">bold</span>, &quot;quoted&quot;"))
        #expect(XMLParser(data: Data(written.utf8)).parse())
    }

    // MARK: LRC

    @Test func lrcMultipleTimestampsOffsetAndMetadata() throws {
        let lrc = """
        [ar:Someone]
        [ti:Song]
        [offset:+500]
        [00:12.00][01:02.50]Chorus line
        [00:15.30]Verse <00:15.80>word
        [00:20.00]
        [61:00.00]Late line
        """
        let parsed = LRCFormat.parse(lrc)
        #expect(parsed.cues == [
            Cue(start: 11_500, end: 14_800, text: "Chorus line"),
            Cue(start: 14_800, end: 19_500, text: "Verse word"),
            Cue(start: 62_000, end: 3_659_500, text: "Chorus line"),
            Cue(start: 3_659_500, end: 3_663_500, text: "Late line"),
        ])
        let (written, notes) = try Self.convert(Self.sampleSRT, from: .srt, to: .lrc)
        #expect(written.contains("[62:03.04]Second line\n[62:03.04]with a break\n"))
        #expect(notes == [.subtitleStylingRemoved, .subtitleEndTimesDropped])
    }

    // MARK: MicroDVD

    @Test func microDVDFrameRateHeaderAndStyles() throws {
        let sub = "{1}{1}25\n{0}{25}{y:i}Italic line|plain line\n{50}{75}{Y:b}{c:$0000FF}Bold all|second\n{100}{}Open ended\n{200}{250}Last\n"
        let parsed = MicroDVDFormat.parse(sub, frameRate: nil)
        #expect(parsed.cues == [
            Cue(start: 0, end: 1_000, text: "<i>Italic line</i>\nplain line"),
            Cue(start: 2_000, end: 3_000, text: "<b>Bold all\nsecond</b>"),
            Cue(start: 4_000, end: 8_000, text: "Open ended"),
            Cue(start: 8_000, end: 10_000, text: "Last"),
        ])
        #expect(parsed.notes == [.subtitleStylingRemoved])
    }

    @Test func microDVDWithoutHeaderAssumesAFrameRate() throws {
        let sub = "{24}{48}Hello|world\n"
        let parsed = MicroDVDFormat.parse(sub, frameRate: nil)
        #expect(parsed.cues == [Cue(start: 1_001, end: 2_002, text: "Hello\nworld")])
        #expect(parsed.notes == [.subtitleFrameRateAssumed])
        #expect(MicroDVDFormat.parse(sub, frameRate: 24).cues == [Cue(start: 1_000, end: 2_000, text: "Hello\nworld")])

        let (written, notes) = try Self.convert("1\n00:00:01,000 --> 00:00:02,000\n<i>Hi</i>\nthere\n", from: .srt, to: .microDVD,
                                                options: ConversionOptions(subtitleFrameRate: 25))
        #expect(written == "{1}{1}25\n{25}{50}{y:i}Hi|there\n")
        #expect(notes == [.subtitleFrameRateAssumed])
    }

    // MARK: SAMI

    @Test func samiKeepsTheFirstLanguageAndClearsOnNbsp() throws {
        let smi = """
        <SAMI><HEAD><STYLE TYPE="text/css"><!-- P {color:white} .ENUSCC {Name:English;} .FRFRCC {Name:French;} --></STYLE></HEAD>
        <BODY>
        <SYNC Start=1000><P Class=ENUSCC>Hello<br>there &amp; <i>you</i>
        <P Class=FRFRCC>Bonjour
        <SYNC Start=2500><P Class=ENUSCC>&nbsp;
        <SYNC Start="3000"><P Class=ENUSCC><font color="red">Red</font>
          text &#8212; done
        </BODY></SAMI>
        """
        let parsed = SAMIFormat.parse(smi)
        #expect(parsed.cues == [
            Cue(start: 1_000, end: 2_500, text: "Hello\nthere & <i>you</i>"),
            Cue(start: 3_000, end: 7_000, text: "Red text — done"),
        ])
        #expect(parsed.notes == [.subtitleStylingRemoved])
    }

    // MARK: Options

    @Test func timeShiftMovesEveryCue() throws {
        let (shifted, _) = try Self.convert(Self.sampleSRT, from: .srt, to: .srt,
                                            options: ConversionOptions(subtitleShiftMilliseconds: -1_500))
        let (cues, _) = SubtitleConverter.parse(shifted)
        #expect(cues.first == Cue(start: 0, end: 1_000, text: "Hello there"))
        #expect(cues[1].start == 3_721_540)
        let (dropped, _) = try Self.convert(Self.sampleSRT, from: .srt, to: .vtt,
                                            options: ConversionOptions(subtitleShiftMilliseconds: -3_000))
        #expect(SubtitleConverter.parse(dropped).0.count == Self.samples.count - 1)
    }
}
