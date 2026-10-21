import Foundation
import Testing
@testable import AmeyaCore

@Suite("Audio and video tool requests")
struct MediaToolTests {
    @Test("Every tool survives the trip to the worker as JSON", arguments: [
        MediaTool.evenVolume(.broadcast), .fade(inSeconds: 1, outSeconds: 2.5), .trimAudio(start: 1, end: nil), .speed(1.5),
        .channels(.rightOnly), .joinAudio, .joinVideos, .audiobook(title: "Book", chapterTitles: ["One", "Two"]),
        .ringtone(start: 12, seconds: 30), .gif(targetBytes: 5_000_000), .extractFrames(.everyFrames(10), format: .jpeg),
        .burnSubtitles, .autoCaption, .visualiser(style: .wave, background: VisualiserColor(red: 0.1, green: 0.2, blue: 0.3)),
    ])
    func roundTrips(tool: MediaTool) throws {
        var options = ConversionOptions()
        options.media = tool
        let request = ConversionRequest(source: .wav, target: .m4a, options: options)
        let decoded = try JSONDecoder().decode(ConversionRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
        #expect(decoded.options.hasEdits)
    }

    @Test func olderRequestsWithoutMediaStillDecode() throws {
        let json = try JSONEncoder().encode(ConversionRequest(source: .wav, target: .m4a))
        #expect(try JSONDecoder().decode(ConversionRequest.self, from: json).options.media == nil)
    }

    @Test func loudnessTargets() {
        #expect(LoudnessTarget.podcast.lufs == -16 && LoudnessTarget.streaming.lufs == -14 && LoudnessTarget.broadcast.lufs == -23)
        #expect(LoudnessTarget.truePeakCeiling == -1)
    }

    @Test func outputExtensionCanBeChosen() {
        let source = URL(fileURLWithPath: "/tmp/chapter one.wav")
        let book = OutputPlanner.destination(for: source, target: .m4a, in: URL(fileURLWithPath: "/tmp/out"),
                                             suffix: "(audiobook)", fileExtension: "m4b") { _ in false }
        #expect(book.lastPathComponent == "chapter one (audiobook).m4b")
        let plain = OutputPlanner.destination(for: source, target: .m4a, in: URL(fileURLWithPath: "/tmp/out")) { _ in false }
        #expect(plain.lastPathComponent == "chapter one.m4a")
    }

    @Test func onlyFrameExtractionMakesAFolder() {
        #expect(MediaTool.extractFrames(.everySeconds(1), format: .png).producesSeveralFiles)
        #expect(!MediaTool.gif(targetBytes: 1).producesSeveralFiles)
    }
}
