import AmeyaCore
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AmeyaEngines

/// Even volume, fades, trim, speed, channels, joining, audiobooks and ringtones, on generated tones.
@Suite("Audio tools", .serialized)
@MainActor
struct AudioToolsTests {
    let directory: URL
    init() throws { directory = try AVMedia.directory() }

    // MARK: The meter

    @Test func meterReadsAStereoSineAtItsLevel() throws {
        // BS.1770: a 997 Hz sine at −20 dBFS in both channels reads −20 LUFS (±0.1).
        let rate = 48_000.0
        let meter = LoudnessMeter(sampleRate: rate, channels: 2)
        let samples = (0..<Int(rate * 5)).map { Float(0.1 * sin(2 * .pi * 997 * Double($0) / rate)) }
        meter.add([samples, samples])
        let lufs = try #require(meter.integratedLoudness)
        #expect(abs(lufs - -20) < 0.1, "\(lufs)")
        #expect(abs(meter.truePeakDB - -20) < 0.1)
    }

    @Test func truePeakFindsPeaksBetweenSamples() {
        // A quarter-rate sine sampled 45° off its crests: every sample is ±0.707, the wave reaches 1.
        let samples = (0..<4_800).map { Float(sin(Double.pi / 2 * Double($0) + .pi / 4)) }
        let meter = LoudnessMeter(sampleRate: 48_000, channels: 1)
        meter.add([samples])
        #expect(samples.map(abs).max()! < 0.71)
        #expect(meter.truePeakDB > -0.6, "\(meter.truePeakDB) dBTP")
    }

    @Test func silenceHasNoLoudness() {
        let meter = LoudnessMeter(sampleRate: 44_100, channels: 2)
        meter.add([[Float](repeating: 0, count: 88_200), [Float](repeating: 0, count: 88_200)])
        #expect(meter.integratedLoudness == nil)
    }

    // MARK: Even volume

    @Test("Even volume reaches each target within 0.5 LU with true peak ≤ −1 dBTP", arguments: LoudnessTarget.allCases)
    func evenVolumeHitsTarget(target: LoudnessTarget) async throws {
        let quiet = try AVMedia.wav(seconds: 6, in: directory, left: AVMedia.sine(440, amplitude: 0.03))
        let (outputs, result) = try await runTool(.evenVolume(target), inputs: [quiet], formats: [.wav], target: .wav, in: directory)
        let measured = try await AVMedia.loudness(of: outputs[0])
        #expect(abs(measured.lufs - target.lufs) <= 0.5, "\(measured.lufs) LUFS for \(target.lufs)")
        #expect(measured.truePeak <= -1.0, "\(measured.truePeak) dBTP")
        #expect(result.notes == [.volumeEvened])
        if let reference = AVMedia.referenceLoudness(of: outputs[0]) {
            #expect(abs(reference.lufs - target.lufs) <= 0.5, "FFmpeg ebur128: \(reference.lufs) LUFS")
            #expect(reference.truePeak <= -1.0, "FFmpeg ebur128: \(reference.truePeak) dBTP")
        }
    }

    @Test("Loud peaks are limited and AAC output stays under −1 dBTP", arguments: [FileFormat.m4a, .flac])
    func limiterHoldsPeaks(target: FileFormat) async throws {
        let input = try AVMedia.wav(seconds: 8, in: directory, left: AVMedia.peaky)
        let (outputs, _) = try await runTool(.evenVolume(.streaming), inputs: [input], formats: [.wav], target: target, in: directory)
        let measured = try await AVMedia.loudness(of: outputs[0])
        #expect(abs(measured.lufs - -14) <= 0.5, "\(measured.lufs) LUFS")
        #expect(measured.truePeak <= -1.0, "\(measured.truePeak) dBTP")
        if let reference = AVMedia.referenceLoudness(of: outputs[0]) {
            #expect(abs(reference.lufs - -14) <= 0.5, "FFmpeg ebur128: \(reference.lufs) LUFS")
            #expect(reference.truePeak <= -1.0, "FFmpeg ebur128: \(reference.truePeak) dBTP")
        }
    }

    @Test func evenVolumeKeepsAVideosPicture() async throws {
        let clip = try await AVMedia.clip(width: 64, height: 48, frames: 30, in: directory, withAudio: true)
        let (outputs, _) = try await runTool(.evenVolume(.podcast), inputs: [clip], formats: [.mp4], target: .mp4, in: directory)
        let asset = AVURLAsset(url: outputs[0])
        #expect(try await !asset.loadTracks(withMediaType: .video).isEmpty)
        let measured = try await AVMedia.loudness(of: outputs[0])
        #expect(abs(measured.lufs - -16) <= 0.5, "\(measured.lufs) LUFS")
        #expect(measured.truePeak <= -1.0)
    }

    @Test func silentFileIsRefused() async throws {
        let silent = try AVMedia.wav(seconds: 2, in: directory, left: { _ in 0 })
        await #expect(throws: ConversionError.self) {
            try await runTool(.evenVolume(.podcast), inputs: [silent], formats: [.wav], target: .wav, in: directory)
        }
    }

    // MARK: Fades, trim, speed, channels

    @Test func fadesStartAndEndQuietly() async throws {
        let tone = try AVMedia.wav(seconds: 4, in: directory, left: AVMedia.sine(440, amplitude: 0.5))
        let (outputs, result) = try await runTool(.fade(inSeconds: 1, outSeconds: 1), inputs: [tone], formats: [.wav],
                                                  target: .wav, in: directory)
        let start = try AVMedia.rms(of: outputs[0], from: 0, to: 0.1)[0]
        let middle = try AVMedia.rms(of: outputs[0], from: 1.8, to: 2.2)[0]
        let end = try AVMedia.rms(of: outputs[0], from: 3.9, to: 4.0)[0]
        #expect(middle > 0.3)
        #expect(start < middle * 0.1, "\(start) vs \(middle)")
        #expect(end < middle * 0.1, "\(end) vs \(middle)")
        #expect(result.notes == [.fadedInOut])
    }

    @Test func trimKeepsTheChosenPart() async throws {
        let tone = try AVMedia.wav(seconds: 3, in: directory, left: AVMedia.sine(440, amplitude: 0.5))
        let (outputs, _) = try await runTool(.trimAudio(start: 0.5, end: 2), inputs: [tone], formats: [.wav], target: .m4a, in: directory)
        #expect(abs(try await AVMedia.duration(of: outputs[0]) - 1.5) < 0.05)
        #expect(FileFormat.detect(at: outputs[0]) == .m4a)
    }

    @Test("Speed changes the length, not the pitch", arguments: [0.5, 1.5, 2.0])
    func speedKeepsPitch(factor: Double) async throws {
        let tone = try AVMedia.wav(seconds: 2, in: directory, left: AVMedia.sine(440, amplitude: 0.5))
        let (outputs, result) = try await runTool(.speed(factor), inputs: [tone], formats: [.wav], target: .wav, in: directory)
        let seconds = try await AVMedia.duration(of: outputs[0])
        #expect(abs(seconds - 2 / factor) <= 2 / factor * 0.02, "\(seconds) s at \(factor)×")
        #expect(abs(try AVMedia.frequency(of: outputs[0]) - 440) < 440 * 0.05)
        #expect(result.notes == [.speedChanged])
    }

    @Test func channelsSwapMonoAndOneSide() async throws {
        let leftOnly = try AVMedia.wav(seconds: 1, in: directory, left: AVMedia.sine(440, amplitude: 0.5), right: { _ in 0 })
        let swapped = try await runTool(.channels(.swap), inputs: [leftOnly], formats: [.wav], target: .wav, in: directory).outputs[0]
        let levels = try AVMedia.rms(of: swapped, from: 0.2, to: 0.8)
        #expect(levels.count == 2 && levels[0] < 0.01 && levels[1] > 0.3, "\(levels)")

        let mono = try await runTool(.channels(.mono), inputs: [leftOnly], formats: [.wav], target: .wav, in: directory).outputs[0]
        let monoLevels = try AVMedia.rms(of: mono, from: 0.2, to: 0.8)
        #expect(monoLevels.count == 1 && abs(monoLevels[0] - 0.177) < 0.02, "\(monoLevels)")

        let right = try await runTool(.channels(.rightOnly), inputs: [leftOnly], formats: [.wav], target: .wav, in: directory).outputs[0]
        let rightLevels = try AVMedia.rms(of: right, from: 0.2, to: 0.8)
        #expect(rightLevels.count == 1 && rightLevels[0] < 0.01)
    }

    // MARK: Join, audiobook, ringtone

    @Test func joinAddsTheLengths() async throws {
        let first = try AVMedia.wav(seconds: 1, in: directory, left: AVMedia.sine(440, amplitude: 0.3))
        let second = try AVMedia.wav(seconds: 1.5, sampleRate: 48_000, in: directory, left: AVMedia.sine(660, amplitude: 0.3))
        let (outputs, result) = try await runTool(.joinAudio, inputs: [first, second], formats: [.wav, .wav], target: .m4a, in: directory)
        #expect(abs(try await AVMedia.duration(of: outputs[0]) - 2.5) < 0.06)
        #expect(result.notes == [.joinedInOrder])
    }

    @Test func audiobookHasAChapterPerFileAndACover() async throws {
        let parts = try [1.0, 1.5, 2.0].map { try AVMedia.wav(seconds: $0, in: directory, left: AVMedia.sine(440, amplitude: 0.3)) }
        let cover = directory.appendingPathComponent("cover.png")
        try AVMedia.png(width: 300, height: 300).write(to: cover)
        let titles = ["Opening", "The middle", "Ending"]
        let (outputs, result) = try await runTool(.audiobook(title: "My book", chapterTitles: titles), inputs: parts + [cover],
                                                  formats: [.wav, .wav, .wav, .png], target: .m4a, in: directory)
        let asset = AVURLAsset(url: outputs[0])
        #expect(abs(try await asset.load(.duration).seconds - 4.5) < 0.1)
        let locales = try await asset.load(.availableChapterLocales)
        let groups = try await asset.loadChapterMetadataGroups(withTitleLocale: locales.first ?? Locale(identifier: "und"),
                                                               containingItemsWithCommonKeys: [])
        #expect(groups.count == 3)
        var found: [String] = []
        for group in groups {
            let item = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
            found.append(try await item?.load(.stringValue) ?? "")
        }
        #expect(found == titles)
        #expect(abs(groups[1].timeRange.start.seconds - 1.0) < 0.05)
        let metadata = try await asset.load(.metadata)
        #expect(metadata.contains { $0.identifier == .iTunesMetadataCoverArt })
        #expect(result.notes.contains(.chaptersAdded) && result.notes.contains(.coverAdded))
    }

    @Test func ringtoneIsThirtySecondsFromTheStart() async throws {
        let song = try AVMedia.wav(seconds: 45, sampleRate: 22_050, in: directory, left: AVMedia.sine(440, amplitude: 0.4))
        let (outputs, result) = try await runTool(.ringtone(start: 10, seconds: 30), inputs: [song], formats: [.wav], target: .m4a, in: directory)
        #expect(abs(try await AVMedia.duration(of: outputs[0]) - 30) < 0.1)
        #expect(FileFormat.detect(at: outputs[0]) == .m4a)
        #expect(result.notes == [.ringtoneHowTo])

        let short = try await runTool(.ringtone(start: 30, seconds: 30), inputs: [song], formats: [.wav], target: .m4a, in: directory)
        #expect(abs(try await AVMedia.duration(of: short.outputs[0]) - 15) < 0.1)
        #expect(short.result.notes.contains(.ringtoneShorter))
    }
}
