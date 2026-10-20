import AmeyaCore
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AmeyaEngines

/// Audio and video engines, driven with generated tones and clips.
@Suite("Audio and video", .serialized)
struct MediaTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Audio

    @Test("A tone converts to every audio format and keeps its length and signal",
          arguments: [FileFormat.m4a, .alac, .wav, .aiff, .caf, .flac])
    func audioRoundTrip(target: FileFormat) async throws {
        let wav = try Media.tone(seconds: 1, sampleRate: 44_100, in: directory)
        let output = directory.appendingPathComponent("out-\(target.rawValue).\(target.preferredExtension)")
        try await AudioConverter.convert(input: wav, to: target, output: output) { _ in }

        let file = try AVAudioFile(forReading: output)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        #expect(abs(seconds - 1) < 0.06)
        #expect(file.fileFormat.channelCount == 2)
        #expect(try Media.rms(of: file) > 0.1)
        let expected = target == .alac ? FileFormat.m4a : target
        #expect(FileFormat.detect(at: output) == expected)
    }

    @Test func aacIsCappedAt48kHz() async throws {
        let wav = try Media.tone(seconds: 0.5, sampleRate: 96_000, in: directory)
        let output = directory.appendingPathComponent("hi-res.m4a")
        try await AudioConverter.convert(input: wav, to: .m4a, output: output) { _ in }
        #expect(try AVAudioFile(forReading: output).fileFormat.sampleRate == 48_000)

        let flac = directory.appendingPathComponent("hi-res.flac")
        try await AudioConverter.convert(input: wav, to: .flac, output: flac) { _ in }
        #expect(try AVAudioFile(forReading: flac).fileFormat.sampleRate == 96_000)
    }

    // MARK: Video

    @Test func gifBecomesVideoWithTheSameTiming() async throws {
        let gif = try Fixtures.encode(Fixtures.frames(6), as: .gif, delay: 0.1)
        let mp4 = directory.appendingPathComponent("anim.mp4")
        _ = try await VideoConverter.gifToVideo(gif, to: .mp4, output: mp4, options: ConversionOptions()) { _ in }
        let asset = AVURLAsset(url: mp4)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 0.6) < 0.05)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 64, height: 48))
    }

    @Test func videoReencodesToOtherContainers() async throws {
        let clip = try await Media.clip(in: directory, withAudio: false)
        for target in [FileFormat.mov, .m4v] {
            let output = directory.appendingPathComponent("clip-out.\(target.preferredExtension)")
            try await VideoConverter.transcode(input: clip, to: target, output: output) { _ in }
            #expect(FileFormat.detect(at: output) == target)
            #expect(try await !AVURLAsset(url: output).loadTracks(withMediaType: .video).isEmpty)
        }
    }

    @Test func videoBecomesAnAnimatedGIF() async throws {
        let clip = try await Media.clip(in: directory, withAudio: false)
        let (gif, notes) = try await VideoConverter.toGIF(input: clip) { _ in }
        #expect(FileFormat.sniff(gif) == .gif)
        #expect((Fixtures.decode(gif)?.count ?? 0) > 1)
        #expect(notes == [.soundRemoved])
    }

    @Test func soundIsExtractedFromVideo() async throws {
        let clip = try await Media.clip(in: directory, withAudio: true)
        let output = directory.appendingPathComponent("sound.m4a")
        try await AudioConverter.convert(input: clip, to: .m4a, output: output) { _ in }
        let file = try AVAudioFile(forReading: output)
        #expect(Double(file.length) / file.fileFormat.sampleRate > 0.4)
        #expect(try Media.rms(of: file) > 0.1)
    }

    @Test func silentVideoHasNoSoundToExtract() async throws {
        let clip = try await Media.clip(in: directory, withAudio: false)
        await #expect(throws: ConversionError.noAudioTrack) {
            try await AudioConverter.convert(input: clip, to: .wav, output: directory.appendingPathComponent("none.wav")) { _ in }
        }
    }

    @Test func audioIsNotAVideo() async throws {
        let wav = try Media.tone(seconds: 0.2, sampleRate: 44_100, in: directory)
        await #expect(throws: ConversionError.noVideoTrack) {
            try await VideoConverter.transcode(input: wav, to: .mp4, output: directory.appendingPathComponent("x.mp4")) { _ in }
        }
    }
}

enum Media {
    /// A 440 Hz stereo tone as 16-bit WAV.
    static func tone(seconds: Double, sampleRate: Double, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("tone-\(Int(sampleRate))-\(UUID().uuidString).wav")
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) { samples[frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate)) }
        }
        try file.write(from: buffer)
        return url
    }

    /// A 0.6 s, 64×48 H.264 clip, optionally with a tone on an audio track.
    static func clip(in directory: URL, withAudio: Bool) async throws -> URL {
        let silent = directory.appendingPathComponent("clip-\(UUID().uuidString).mp4")
        let gif = try Fixtures.encode(Fixtures.frames(6), as: .gif, delay: 0.1)
        _ = try await VideoConverter.gifToVideo(gif, to: .mp4, output: silent, options: ConversionOptions()) { _ in }
        guard withAudio else { return silent }

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: silent)
        let audioAsset = AVURLAsset(url: try tone(seconds: 1, sampleRate: 44_100, in: directory))
        let duration = try await videoAsset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        let videoTrack = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let audioTrack = try #require(try await audioAsset.loadTracks(withMediaType: .audio).first)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: audioTrack, at: .zero)

        let output = directory.appendingPathComponent("clip-av-\(UUID().uuidString).mov")
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        session.outputURL = output
        session.outputFileType = .mov
        await session.export()
        try #require(session.status == .completed, "export failed: \(String(describing: session.error))")
        return output
    }

    /// Root-mean-square level of the first channel, read through the file's processing format.
    static func rms(of file: AVAudioFile) throws -> Float {
        file.framePosition = 0
        let capacity = AVAudioFrameCount(min(file.length, 22_050))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)!
        try file.read(into: buffer, frameCount: capacity)
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }
}
