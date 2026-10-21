import Foundation
import Testing
@testable import AmeyaCore

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
