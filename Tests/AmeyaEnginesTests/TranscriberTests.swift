import AmeyaCore
@preconcurrency import AVFoundation
import Foundation
import Speech
import Testing
@testable import AmeyaEngines

@Suite("Transcription")
struct TranscriberTests {
    typealias Word = Transcriber.Word

    /// Words spoken back to back, 300 ms each, starting at `start`.
    func speak(_ sentence: String, from start: Int = 0, step: Int = 300) -> [Word] {
        sentence.split(separator: " ").enumerated().map { index, text in
            Word(text: String(text), start: start + index * step, end: start + (index + 1) * step)
        }
    }

    @Test func sentenceEndsStartNewCaptions() {
        let cues = Transcriber.cues(from: speak("Hello there. How are you today?"))
        #expect(cues.map(\.text) == ["Hello there.", "How are you today?"])
        #expect(cues[0].start == 0)
        #expect(cues[1].start == 600)
        #expect(cues[1].end == 1_800)
    }

    @Test func pausesStartNewCaptions() {
        let words = speak("first part here") + speak("after the pause", from: 2_500)
        let cues = Transcriber.cues(from: words)
        #expect(cues.map(\.text) == ["first part here", "after the pause"])
    }

    @Test func captionsRespectLineLengthAndTwoLines() {
        let long = Array(repeating: "word", count: 60).joined(separator: " ")
        let cues = Transcriber.cues(from: speak(long, step: 100))
        #expect(cues.count > 1)
        for cue in cues {
            let lines = cue.text.split(separator: "\n")
            #expect(lines.count <= 2)
            #expect(lines.allSatisfy { $0.count <= 42 })
        }
        // Every word survives, in order.
        let rejoined = cues.map { $0.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " ")
        #expect(rejoined == long)
    }

    @Test func captionsLastAtMostSevenSeconds() {
        let slow = speak("one two three four five six seven eight nine ten", step: 1_000)
        let cues = Transcriber.cues(from: slow)
        #expect(cues.allSatisfy { $0.end - $0.start <= 7_000 })
        #expect(cues.count == 2)
    }

    @Test func shortCaptionsStayUpForASecondWithoutOverlapping() {
        let words = [Word(text: "Yes.", start: 0, end: 200), Word(text: "No.", start: 500, end: 700), Word(text: "Maybe.", start: 3_000, end: 3_200)]
        let cues = Transcriber.cues(from: words)
        #expect(cues.map(\.end) == [500, 1_500, 4_000])
        for (cue, next) in zip(cues, cues.dropFirst()) { #expect(cue.end <= next.start) }
    }

    @Test func clauseBreaksOnceALineIsFull() {
        let text = "When the meeting started on Monday morning, everyone was already there"
        let cues = Transcriber.cues(from: speak(text, step: 150))
        #expect(cues.first?.text.replacingOccurrences(of: "\n", with: " ") == "When the meeting started on Monday morning,")
    }

    @Test func wrapBalancesTwoLines() {
        let lines = Transcriber.wrap("The quick brown fox jumps over the lazy dog and keeps running")
        #expect(lines?.count == 2)
        #expect(lines?.allSatisfy { $0.count <= 42 } == true)
        #expect(Transcriber.wrap("Short line") == ["Short line"])
        #expect(Transcriber.wrap(String(repeating: "a ", count: 60)) == nil)
    }

    @Test func phrasesShareTheirTimeRangeByLength() {
        let words = Transcriber.words(in: " The quick ", start: 1_000, end: 2_000)
        #expect(words.map(\.text) == ["The", "quick"])
        #expect(words.first?.start == 1_000)
        #expect(words.last?.end == 2_000)
        #expect(words[0].end == words[1].start)
    }

    @Test func transcriptSplitsParagraphsAtLongPauses() {
        let words = speak("Hello there.") + speak("New topic.", from: 5_000)
        #expect(Transcriber.transcript(from: words) == "Hello there.\n\nNew topic.\n")
    }

    @Test func rendersCaptionsAsSRTAndVTT() {
        let cues = Transcriber.cues(from: speak("Hello there. How are you today?"))
        #expect(SubtitleConverter.renderSRT(cues).hasPrefix("1\n00:00:00,000 --> 00:00:00,600\nHello there.\n"))
        #expect(SubtitleConverter.renderVTT(cues).hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:00.600\nHello there.\n"))
    }

    @Test func chunksAreCutAtTheQuietestMoment() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 1_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_000))
        buffer.frameLength = 1_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<1_000 { samples[index] = (700..<720).contains(index) ? 0 : 0.5 }
        let cut = LegacyRecogniser.quietestFrame(in: buffer, searchFrames: 500, windowFrames: 20)
        #expect((700..<720).contains(cut))
    }

    @Test func matrixOffersTranscriptsForAudioAndVideo() {
        #expect(ConversionMatrix.canConvert(from: .mp3, to: .srt))
        #expect(ConversionMatrix.canConvert(from: .mov, to: .vtt))
        #expect(ConversionMatrix.canConvert(from: .wav, to: .txt))
        #expect(!ConversionMatrix.canConvert(from: .mp3, to: .docx))
        #expect(ConversionMatrix(writable: []).possibleLosses(from: .m4a, to: .txt) == [.transcribedOnDevice])
    }

    // MARK: - End to end

    /// Synthesises speech with `say`, then transcribes it through the engine. Skipped (with a
    /// message) when this Mac can't recognise English on-device, as on most CI runners.
    @Test @MainActor func transcribesSynthesisedSpeech() async throws {
        guard let reason = await Self.recognitionUnavailableReason() else {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-stt-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let speech = directory.appendingPathComponent("speech.aiff")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", "Samantha", "-o", speech.path, "The quick brown fox jumps over the lazy dog. Then it goes to sleep."]
            try say.run()
            say.waitUntilExit()
            guard say.terminationStatus == 0 else {
                print("SKIPPED transcription end-to-end test: `say` couldn't synthesise speech")
                return
            }

            var options = ConversionOptions()
            options.language = "en-US"
            let (srtURL, result) = try await Engine.convert(
                input: speech, request: ConversionRequest(source: .aiff, target: .srt, options: options), scratch: directory
            ) { _ in }
            let srt = try String(contentsOf: srtURL, encoding: .utf8)
            print("Transcribed SRT:\n\(srt)")
            #expect(result.notes == [.transcribedOnDevice])
            #expect(srt.hasPrefix("1\n00:00:0"))
            #expect(srt.lowercased().contains("fox"))
            #expect(srt.lowercased().contains("lazy dog"))
            #expect(!SubtitleConverter.parse(srt).0.isEmpty)
            return
        }
        print("SKIPPED transcription end-to-end test: \(reason)")
    }

    static func recognitionUnavailableReason() async -> String? {
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
            return installed.contains("en-US") ? nil : "the en-US speech model isn't installed on this Mac"
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return "speech recognition isn't authorised for this process"
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.supportsOnDeviceRecognition else {
            return "on-device English recognition isn't available"
        }
        return nil
    }
}
