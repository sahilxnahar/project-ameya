import AmeyaCore
import AVFoundation
import Foundation

/// Self-test checks for the audio and video tools, run through the sandboxed worker exactly as the
/// app runs them: even volume, speed, joining sound (several inputs), an audiobook with chapters,
/// a ringtone, a GIF under a size, frames into a folder, burned-in subtitles and a visualiser.
extension SelfTest.Checker {
    mutating func checkAVTools() async {
        let catalog = ToolCatalog(writable: FileFormat.systemWritable())
        func tool(_ id: String) -> Tool { catalog.tools.first { $0.id == id }! }
        func request(_ id: String, _ format: FileFormat, _ media: MediaTool, inputs: [FileFormat]? = nil) -> ConversionRequest {
            var request = tool(id).makeRequest(format)
            request.options.media = media
            request.inputs = inputs
            return request
        }

        do {
            let quiet = directory.appendingPathComponent("quiet talk.wav")
            try AVToolSamples.tone(seconds: 4, amplitude: 0.03, to: quiet)
            let even = directory.appendingPathComponent("quiet talk (even volume).wav")
            if let result = await run([quiet], to: even, request("media.evenVolume", .wav, .evenVolume(.podcast))) {
                let gain = AVToolSamples.peak(of: even) / 0.03
                verify(gain > 3 && result.notes == [.volumeEvened], "even volume", "peak ×\(String(format: "%.1f", gain))")
            }

            let fast = directory.appendingPathComponent("quiet talk (2x).wav")
            if await run([quiet], to: fast, request("media.speed", .wav, .speed(2))) != nil {
                let seconds = await AVToolSamples.duration(fast)
                verify(abs(seconds - 2) < 0.05, "speed 2x", "\(seconds) s")
            }

            let second = directory.appendingPathComponent("second part.wav")
            try AVToolSamples.tone(seconds: 1.5, amplitude: 0.3, to: second)
            let joined = directory.appendingPathComponent("quiet talk (joined).m4a")
            if await run([quiet, second], to: joined, request("media.joinAudio", .wav, .joinAudio, inputs: [.wav, .wav])) != nil {
                let seconds = await AVToolSamples.duration(joined)
                verify(abs(seconds - 5.5) < 0.1, "join audio", "\(seconds) s")
            }

            var bookRequest = request("media.audiobook", .wav, .audiobook(title: "Self-test", chapterTitles: []), inputs: [.wav, .wav])
            tool("media.audiobook").finishRequest?(&bookRequest, [quiet, second])
            let book = OutputPlanner.destination(for: quiet, target: .m4a, in: directory, suffix: "(audiobook)", fileExtension: "m4b") { _ in false }
            if await run([quiet, second], to: book, bookRequest) != nil {
                let asset = AVURLAsset(url: book)
                let locales = (try? await asset.load(.availableChapterLocales)) ?? []
                let chapters = (try? await asset.loadChapterMetadataGroups(withTitleLocale: locales.first ?? Locale(identifier: "und"),
                                                                           containingItemsWithCommonKeys: [])) ?? []
                verify(chapters.count == 2 && book.pathExtension == "m4b", "audiobook chapters", "\(chapters.count) chapters, .\(book.pathExtension)")
            }

            let song = directory.appendingPathComponent("song.wav")
            try AVToolSamples.tone(seconds: 40, amplitude: 0.3, sampleRate: 22_050, to: song)
            let ringtone = directory.appendingPathComponent("song (ringtone).m4r")
            if await run([song], to: ringtone, request("media.ringtone", .wav, .ringtone(start: 5, seconds: 30))) != nil {
                let seconds = await AVToolSamples.duration(ringtone)
                verify(abs(seconds - 30) < 0.1, "ringtone 30 s", "\(seconds) s")
            }

            let clip = directory.appendingPathComponent("av clip.mov")
            try await PresetSamples.clip(to: clip, in: directory)
            let gif = directory.appendingPathComponent("av clip (GIF).gif")
            if let result = await run([clip], to: gif, request("media.gif", .mov, .gif(targetBytes: 1_000_000))) {
                let bytes = AVToolSamples.size(gif)
                verify(bytes > 0 && bytes <= 1_000_000 && FileFormat.detect(at: gif) == .gif, "GIF under 1 MB",
                       "\(bytes) bytes \(result.notes.map(\.rawValue))")
            }

            let frames = directory.appendingPathComponent("av clip (frames)", isDirectory: true)
            if let result = await run([clip], to: frames, request("media.frames", .mov, .extractFrames(.everySeconds(1), format: .jpeg))) {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: frames.path)) ?? []
                verify(files.count == 3 && result.outputNames?.count == 3, "frames every second", "\(files.sorted())")
            }

            let srt = directory.appendingPathComponent("av clip.srt")
            try Data("1\n00:00:00,500 --> 00:00:02,000\nCaptions drawn in\n\n".utf8).write(to: srt)
            let captioned = directory.appendingPathComponent("av clip (captions).mp4")
            if await run([clip, srt], to: captioned, request("media.burnSubtitles", .mov, .burnSubtitles, inputs: [.mov, .srt])) != nil {
                let seconds = await AVToolSamples.duration(captioned)
                verify(abs(seconds - 3) < 0.15 && FileFormat.detect(at: captioned) == .mp4, "burn in subtitles", "\(seconds) s")
            }

            let visual = directory.appendingPathComponent("song (video).mp4")
            let short = directory.appendingPathComponent("short song.wav")
            try AVToolSamples.tone(seconds: 2, amplitude: 0.3, to: short)
            let style = MediaTool.visualiser(style: .bars, background: VisualiserColor(red: 0.1, green: 0.1, blue: 0.3))
            if await run([short], to: visual, request("media.visualiser", .wav, style)) != nil {
                let seconds = await AVToolSamples.duration(visual)
                verify(abs(seconds - 2) < 0.1, "sound to video", "\(seconds) s")
            }
        } catch {
            verify(false, "audio and video tools setup", "\(error)")
        }
    }

    private mutating func run(_ inputs: [URL], to destination: URL, _ request: ConversionRequest) async -> ConversionResult? {
        do {
            return try await runner.run(inputs: inputs, destination: destination, request: request)
        } catch {
            verify(false, destination.lastPathComponent, error.localizedDescription)
            return nil
        }
    }

    private mutating func verify(_ passed: Bool, _ label: String, _ detail: String) {
        print(passed ? "PASS av \(label): \(detail)" : "FAIL av \(label): \(detail)")
        if !passed { allPassed = false }
    }
}

/// Generated sounds and simple measurements for the audio and video self-test.
enum AVToolSamples {
    static func tone(seconds: Double, amplitude: Float, sampleRate: Double = 44_100, to url: URL) throws {
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) { samples[frame] = amplitude * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate)) }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        try file.write(from: buffer)
    }

    static func peak(of url: URL) -> Float {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let samples = buffer.floatChannelData?[0] else { return 0 }
        var peak: Float = 0
        for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[index])) }
        return peak
    }

    static func duration(_ url: URL) async -> Double {
        (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
    }

    static func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
