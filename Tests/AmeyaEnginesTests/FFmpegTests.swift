import AmeyaCore
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AmeyaEngines

/// The helper used by these tests: `AMEYA_FFMPEG`, or the one `scripts/build-ffmpeg.sh` built.
enum FFmpegHelper {
    static let url: URL? = {
        if let helper = FFmpegAvailability.helperURL { return helper }
        let built = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build-deps/ffmpeg/bin/ameya-ffmpeg")
        return FileManager.default.isExecutableFile(atPath: built.path) ? built : nil
    }()
}

/// Planning and error mapping. These don't need the helper.
@Suite("FFmpeg planning")
struct FFmpegPlanningTests {
    let sample = """
    Input #0, matroska,webm, from 'input.mkv':
      Duration: 00:01:02.50, start: 0.000000, bitrate: 1200 kb/s
      Stream #0:0[0x1](eng): Video: h264 (High), yuv420p(progressive), 1920x1080, 25 fps, 25 tbr
      Stream #0:1(eng): Audio: opus, 48000 Hz, 5.1, fltp (default)
      Stream #0:2: Video: mjpeg (Baseline), yuvj420p, 600x600 (attached pic)
    """

    @Test func parsesDurationAndStreams() {
        let probe = FFmpegConverter.parseProbe(sample)
        #expect(probe.duration == 62.5)
        #expect(probe.video?.index == 0)
        #expect(probe.video?.codec == "h264")
        #expect(probe.audio?.index == 1)
        #expect(probe.audio?.codec == "opus")
    }

    @Test func copiesCompatibleStreamsAndReencodesTheRest() throws {
        let probe = FFmpegConverter.parseProbe(sample)
        let input = URL(fileURLWithPath: "/tmp/in.mkv")
        func args(_ target: FileFormat, copy: Bool = true) throws -> String {
            try FFmpegConverter.arguments(for: probe, to: target, input: input,
                                          output: URL(fileURLWithPath: "/tmp/out"), allowCopy: copy).joined(separator: " ")
        }
        #expect(try args(.mp4).contains("-c:v copy"))
        #expect(try args(.mp4).contains("-c:a aac"))
        #expect(try args(.mp4, copy: false).contains("h264_videotoolbox"))
        #expect(try args(.webm).contains("libvpx-vp9"))
        #expect(try args(.webm).contains("-c:a copy"))
        #expect(try args(.avi).contains("-c:v mpeg4"))
        #expect(try args(.avi).contains("libmp3lame"))
        #expect(try args(.opus).contains("-c:a copy"))
        #expect(try args(.mp3).contains("-q:a 2 -ac 2")) // 5.1 is mixed down to stereo
        #expect(try args(.ogg).contains("libvorbis"))
        #expect(!(try args(.wav)).contains("0:0")) // sound only
    }

    @Test func missingStreamsAreReported() {
        let audioOnly = FFmpegConverter.parseProbe("Input #0, ogg\n  Duration: 00:00:01.00\n  Stream #0:0: Audio: vorbis, 44100 Hz, stereo, fltp")
        let url = URL(fileURLWithPath: "/tmp/x")
        #expect(throws: ConversionError.noVideoTrack) {
            try FFmpegConverter.arguments(for: audioOnly, to: .mkv, input: url, output: url, allowCopy: true)
        }
        #expect(throws: ConversionError.noAudioTrack) {
            try FFmpegConverter.arguments(for: FFmpegConverter.Probe(), to: .mp3, input: url, output: url, allowCopy: true)
        }
    }

    @Test func helperErrorsBecomeReadableMessages() {
        #expect(FFmpegConverter.error(from: "x.bin: Invalid data found when processing input\n") == .unreadable)
        #expect(FFmpegConverter.error(from: "") == .mediaFailed("the media helper stopped unexpectedly"))
        #expect(FFmpegConverter.error(from: "[aac @ 0x1] Error while opening encoder\n")
            == .mediaFailed("the encoder couldn't start ([aac @ 0x1] Error while opening encoder)"))
    }
}

/// Real conversions through the helper. Skipped when no helper has been built.
@Suite("FFmpeg conversions", .serialized,
       .enabled(if: FFmpegHelper.url != nil, "ameya-ffmpeg not found: run scripts/build-ffmpeg.sh or set AMEYA_FFMPEG"))
struct FFmpegTests {
    let directory: URL
    let helper: URL

    init() throws {
        helper = try #require(FFmpegHelper.url)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-ffmpeg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func convert(_ input: URL, to target: FileFormat) async throws -> URL {
        let output = directory.appendingPathComponent("out-\(UUID().uuidString).\(target.preferredExtension)")
        try await FFmpegConverter.convert(input: input, to: target, output: output, helper: helper) { _ in }
        return output
    }

    /// Decodes any audio file to WAV with the helper and measures it with AVFoundation.
    func decodedLevel(_ url: URL) async throws -> (seconds: Double, rms: Float) {
        let wav = try await convert(url, to: .wav)
        let file = try AVAudioFile(forReading: wav)
        return (Double(file.length) / file.fileFormat.sampleRate, try Media.rms(of: file))
    }

    @Test("A tone becomes MP3, Ogg Vorbis and Opus that decode to the same sound",
          arguments: [FileFormat.mp3, .ogg, .opus])
    func compressedAudio(target: FileFormat) async throws {
        let tone = try Media.tone(seconds: 1, sampleRate: 44_100, in: directory)
        let output = try await convert(tone, to: target)
        #expect(FileFormat.detect(at: output) == target)
        let (seconds, rms) = try await decodedLevel(output)
        #expect(abs(seconds - 1) < 0.1)
        #expect(rms > 0.1)
        let probe = try await FFmpegConverter.probe(output, helper: helper)
        #expect(probe.audio != nil && probe.video == nil)
        #expect(abs((probe.duration ?? 0) - 1) < 0.1)
    }

    @Test("Ogg and Opus convert back to Apple formats", arguments: [FileFormat.m4a, .alac, .wav, .aiff, .caf, .flac])
    func backToAppleAudio(target: FileFormat) async throws {
        let tone = try Media.tone(seconds: 1, sampleRate: 44_100, in: directory)
        for source in [FileFormat.ogg, .opus] {
            let compressed = try await convert(tone, to: source)
            let output = try await convert(compressed, to: target)
            #expect(FileFormat.detect(at: output) == (target == .alac ? .m4a : target))
            let file = try AVAudioFile(forReading: output)
            #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 1) < 0.1)
            #expect(try Media.rms(of: file) > 0.1)
        }
    }

    @Test("A clip becomes MKV, WebM and AVI and comes back as MP4", arguments: [FileFormat.mkv, .webm, .avi])
    func videoContainers(target: FileFormat) async throws {
        let clip = try await Media.clip(in: directory, withAudio: true)
        let output = try await convert(clip, to: target)
        #expect(FileFormat.detect(at: output) == target)
        let probe = try await FFmpegConverter.probe(output, helper: helper)
        #expect(probe.video != nil)
        #expect(probe.audio != nil)
        let seconds = probe.duration ?? 0
        // In a six-frame clip, the last frame's length and encoder padding add up to a few tenths.
        #expect(seconds > 0.55 && seconds < 0.95, "\(target) lasts \(seconds) s")

        for back in [FileFormat.mp4, .mov] {
            let returned = try await convert(output, to: back)
            #expect(FileFormat.detect(at: returned) == back)
            let asset = AVURLAsset(url: returned)
            #expect(try await !asset.loadTracks(withMediaType: .video).isEmpty)
            #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)
            let duration = try await asset.load(.duration).seconds
            #expect(duration > 0.55 && duration < 0.95, "\(target) -> \(back) lasts \(duration) s")
        }
    }

    @Test func soundComesOutOfAnyVideo() async throws {
        let clip = try await Media.clip(in: directory, withAudio: true)
        let mkv = try await convert(clip, to: .mkv)
        for target in [FileFormat.mp3, .ogg, .opus, .m4a] {
            let sound = try await convert(mkv, to: target)
            #expect(FileFormat.detect(at: sound) == target)
            #expect(try await decodedLevel(sound).rms > 0.1)
        }
    }

    @Test func silentVideoHasNoSoundToExtract() async throws {
        let clip = try await Media.clip(in: directory, withAudio: false)
        await #expect(throws: ConversionError.noAudioTrack) {
            _ = try await convert(clip, to: .mp3)
        }
    }

    @Test func garbageIsUnreadable() async throws {
        let junk = directory.appendingPathComponent("junk.bin")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: junk)
        await #expect(throws: ConversionError.unreadable) {
            _ = try await convert(junk, to: .ogg)
        }
    }

    @Test(.enabled(if: FFmpegAvailability.isAvailable, "AMEYA_FFMPEG not set"))
    func engineRoutesToTheHelper() async throws {
        let tone = try Media.tone(seconds: 0.5, sampleRate: 44_100, in: directory)
        let (output, _) = try await Engine.convert(input: tone, request: ConversionRequest(source: .wav, target: .mp3),
                                                   scratch: directory) { _ in }
        #expect(FileFormat.detect(at: output) == .mp3)
    }
}
