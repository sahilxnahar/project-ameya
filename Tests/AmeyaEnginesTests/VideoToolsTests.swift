import AmeyaCore
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AmeyaEngines

/// Join videos, GIF under a size, frame extraction, burned-in captions and audio visualisers.
@Suite("Video tools", .serialized)
@MainActor
struct VideoToolsTests {
    let directory: URL
    init() throws { directory = try AVMedia.directory() }

    @Test func joinedVideosAddUpAndCopyWhenAlike() async throws {
        let first = try await AVMedia.clip(width: 64, height: 48, frames: 6, in: directory, withAudio: true)
        let second = try await AVMedia.clip(width: 64, height: 48, frames: 10, in: directory)
        let (outputs, result) = try await runTool(.joinVideos, inputs: [first, second], formats: [.mp4, .mp4],
                                                  target: .mp4, in: directory)
        #expect(abs(try await AVMedia.duration(of: outputs[0]) - 1.6) < 0.1)
        #expect(result.notes == [.joinedInOrder])
    }

    @Test func otherShapesAreLetterboxedToTheFirst() async throws {
        let wide = try await AVMedia.clip(width: 320, height: 180, frames: 10, in: directory)
        let tall = try await AVMedia.clip(width: 180, height: 320, frames: 10, in: directory)
        let (outputs, result) = try await runTool(.joinVideos, inputs: [wide, tall], formats: [.mp4, .mp4],
                                                  target: .mp4, in: directory)
        #expect(abs(try await AVMedia.duration(of: outputs[0]) - 2.0) < 0.1)
        #expect(try await PresetMedia.size(of: outputs[0]) == CGSize(width: 320, height: 180))
        #expect(result.notes.contains(.videosLetterboxed))
        // The tall clip sits in the middle with black bars at the sides.
        let frame = try await AVMedia.frame(of: outputs[0], at: 1.5)
        let side = AVMedia.difference(frame, try blank(width: 320, height: 180), in: CGRect(x: 5, y: 40, width: 30, height: 100))
        #expect(side < 12, "side bar differs from black by \(side)")
    }

    @Test func gifFitsUnderTheTarget() async throws {
        let clip = try await PresetMedia.busyClip()
        let target = 1_500_000
        let (outputs, result) = try await runTool(.gif(targetBytes: target), inputs: [clip], formats: [.mp4],
                                                  target: .gif, in: directory)
        let bytes = VideoEditor.fileSize(outputs[0])
        #expect(bytes > 0 && bytes <= target, "\(bytes) bytes")
        #expect(FileFormat.detect(at: outputs[0]) == .gif)
        #expect(result.notes.contains(.gifFittedToSize))
        #expect(!result.notes.contains(.targetSizeNotReached))
    }

    @Test func gifPlansShrink() {
        let next = GIFAndFrames.GIFPlan.first.next(ratio: 0.25, attempt: 0)
        #expect(next.longSide < 480 && next.fps < 12)
        #expect(next.next(ratio: 0.5, attempt: 1).colourBits < 8)
    }

    @Test func framesEverySecondsAndEveryFrames() async throws {
        let clip = try await AVMedia.clip(width: 64, height: 48, frames: 20, in: directory)
        let seconds = try await runTool(.extractFrames(.everySeconds(0.5), format: .png), inputs: [clip], formats: [.mp4],
                                        target: .png, in: directory)
        #expect(seconds.outputs.count == 4)
        #expect(seconds.result.outputNames == ["frame 0001.png", "frame 0002.png", "frame 0003.png", "frame 0004.png"])
        #expect(seconds.outputs.allSatisfy { FileFormat.detect(at: $0) == .png })

        let frames = try await runTool(.extractFrames(.everyFrames(5), format: .jpeg), inputs: [clip], formats: [.mp4],
                                       target: .jpeg, in: directory)
        #expect(frames.outputs.count == 4)
        #expect(frames.outputs.allSatisfy { FileFormat.detect(at: $0) == .jpeg })
    }

    @Test func burnedCaptionsShowOnlyWhileTheyAreOn() async throws {
        let clip = try await AVMedia.clip(width: 640, height: 360, frames: 20, in: directory, withAudio: true)
        let srt = directory.appendingPathComponent("captions.srt")
        try Data("1\n00:00:00,000 --> 00:00:01,000\nHello there, world\n\n".utf8).write(to: srt)
        let (outputs, result) = try await runTool(.burnSubtitles, inputs: [clip, srt], formats: [.mp4, .srt],
                                                  target: .mp4, in: directory)
        #expect(result.notes == [.captionsBurnedIn])
        #expect(try await !AVURLAsset(url: outputs[0]).loadTracks(withMediaType: .audio).isEmpty)
        // Caption area: the bottom fifth, middle half (top-left origin).
        let area = CGRect(x: 160, y: 270, width: 320, height: 70)
        let during = AVMedia.difference(try await AVMedia.frame(of: clip, at: 0.5), try await AVMedia.frame(of: outputs[0], at: 0.5), in: area)
        let after = AVMedia.difference(try await AVMedia.frame(of: clip, at: 1.5), try await AVMedia.frame(of: outputs[0], at: 1.5), in: area)
        #expect(during > 10, "caption area changed by \(during)")
        #expect(after < 6, "caption area changed by \(after) after the caption ended")
    }

    @Test func burnNeedsASubtitleFile() async throws {
        let clip = try await AVMedia.clip(width: 64, height: 48, frames: 6, in: directory)
        await #expect(throws: ConversionError.self) {
            try await runTool(.burnSubtitles, inputs: [clip, clip], formats: [.mp4, .mp4], target: .mp4, in: directory)
        }
    }

    @Test("Visualiser video lasts as long as the sound", arguments: VisualiserStyle.allCases)
    func visualiserMatchesTheSound(style: VisualiserStyle) async throws {
        let tone = try AVMedia.wav(seconds: 2, in: directory, left: AVMedia.peaky)
        let background = VisualiserColor(red: 0.1, green: 0.1, blue: 0.3)
        let (outputs, _) = try await runTool(.visualiser(style: style, background: background), inputs: [tone], formats: [.wav],
                                             target: .mp4, in: directory)
        let asset = AVURLAsset(url: outputs[0])
        #expect(abs(try await asset.load(.duration).seconds - 2) < 0.1)
        #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try await PresetMedia.size(of: outputs[0]) == CGSize(width: 1080, height: 1080))
        // Marks are drawn: the middle row isn't all background.
        let frame = try await AVMedia.frame(of: outputs[0], at: 1.0)
        let plain = try backgroundImage(width: frame.width, height: frame.height, colour: background)
        #expect(AVMedia.difference(frame, plain, in: CGRect(x: 100, y: 500, width: 880, height: 80)) > 10)
    }

    // MARK: Helpers

    private func blank(width: Int, height: Int) throws -> CGImage {
        try backgroundImage(width: width, height: height, colour: VisualiserColor(red: 0, green: 0, blue: 0))
    }

    private func backgroundImage(width: Int, height: Int, colour: VisualiserColor) throws -> CGImage {
        let context = Fixtures.context(width: width, height: height)
        context.setFillColor(CGColor(srgbRed: colour.red, green: colour.green, blue: colour.blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
