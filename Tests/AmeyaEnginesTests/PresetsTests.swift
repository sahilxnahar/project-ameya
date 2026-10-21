import AmeyaCore
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import AmeyaEngines

/// Size presets and video edits: byte targets met, trims accurate, sound removed, frames resized,
/// impossible targets refused early. Driven with a generated 10 s 1080p clip of busy, moving content.
@Suite("Size presets and video edits", .serialized)
@MainActor
struct PresetsTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-presets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func edit(_ input: URL, from source: FileFormat, to target: FileFormat, _ edits: VideoEdits) async throws -> (URL, ConversionResult) {
        let scratch = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let request = ConversionRequest(source: source, target: target, options: ConversionOptions(video: edits))
        return try await Engine.convert(input: input, request: request, scratch: scratch) { _ in }
    }

    // MARK: Planning

    @Test func impossibleTargetsAreRefusedWithAdvice() {
        #expect(throws: ConversionError.self) {
            try VideoBudget.plan(targetBytes: 8_000_000, seconds: 7200, hasAudio: true, width: 1920, height: 1080, fps: 30, maxPixelSize: nil)
        }
        do {
            _ = try VideoBudget.plan(targetBytes: 8_000_000, seconds: 7200, hasAudio: true, width: 1920, height: 1080, fps: 30, maxPixelSize: nil)
        } catch {
            let text = error.localizedDescription
            #expect(text.contains("2-hour") && text.contains("8 MB") && text.contains("minutes"), "\(text)")
        }
    }

    @Test func framesShrinkToWhatTheBitrateCarries() throws {
        let short = try VideoBudget.plan(targetBytes: 25_000_000, seconds: 10, hasAudio: true, width: 1920, height: 1080, fps: 30, maxPixelSize: nil)
        #expect(short.longSide == 1920 && short.audioBitrate == 128_000)
        let minute = try VideoBudget.plan(targetBytes: 10_000_000, seconds: 60, hasAudio: true, width: 1920, height: 1080, fps: 30, maxPixelSize: nil)
        #expect(minute.longSide == 960)
        let capped = try VideoBudget.plan(targetBytes: 16_000_000, seconds: 10, hasAudio: false, width: 1080, height: 1920, fps: 30, maxPixelSize: 1280)
        #expect(capped.longSide == 1280 && capped.audioBitrate == 0)
        #expect(VideoBudget.scaled(width: 1921, height: 1081, longSide: 640) == (640, 360))
        #expect(VideoBudget.scaled(width: 320, height: 240, longSide: 1280) == (320, 240)) // never enlarges
        let retry = VideoBudget.retry(short, actualBytes: 30_000_000, targetBytes: 25_000_000, width: 1920, height: 1080, fps: 30)
        #expect(Double(retry.videoBitrate) <= Double(short.videoBitrate) * 0.85 + 1)
    }

    @Test func trimWindowIsValidated() throws {
        #expect(try VideoBudget.window(VideoEdits(trimStart: 2, trimEnd: 5.5), duration: 10) == (2, 5.5))
        #expect(try VideoBudget.window(VideoEdits(trimStart: nil, trimEnd: 50), duration: 10) == (0, 10))
        #expect(throws: ConversionError.self) { try VideoBudget.window(VideoEdits(trimStart: 12), duration: 10) }
        #expect(throws: ConversionError.self) { try VideoBudget.window(VideoEdits(trimStart: 5, trimEnd: 4), duration: 10) }
    }

    // MARK: AVFoundation

    @Test("Size targets are met", arguments: [25_000_000, 10_000_000, 4_000_000])
    func sizeTargetsAreMet(target: Int) async throws {
        let clip = try await PresetMedia.busyClip()
        let (output, result) = try await edit(clip, from: .mov, to: .mp4, VideoEdits(targetBytes: target))
        let bytes = VideoEditor.fileSize(output)
        print("preset target \(target) bytes: source \(VideoEditor.fileSize(clip)) -> \(bytes) \(result.notes.map(\.rawValue))")
        #expect(bytes <= target)
        #expect(Double(bytes) >= Double(target) * 0.3 || target >= 25_000_000) // uses the budget, not mush
        #expect(result.notes.contains(.videoMadeSmaller) && !result.notes.contains(.targetSizeNotReached))
        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - 10) < 0.2)
        #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)
    }

    @Test func whatsAppPresetIs720pAndUnder16MB() async throws {
        let clip = try await PresetMedia.busyClip()
        let (output, _) = try await edit(clip, from: .mov, to: .mp4, VideoEdits(maxPixelSize: 1280, targetBytes: 16_000_000))
        #expect(VideoEditor.fileSize(output) <= 16_000_000)
        #expect(try await PresetMedia.size(of: output) == CGSize(width: 1280, height: 720))
    }

    @Test func trimIsAccurateAndKeepsTheStreams() async throws {
        let clip = try await PresetMedia.busyClip()
        let (output, result) = try await edit(clip, from: .mov, to: .mov, VideoEdits(trimStart: 2, trimEnd: 5.5))
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 3.5) <= 0.1, "got \(duration) s")
        #expect(result.notes == [.trimmed])
        #expect(try await PresetMedia.size(of: output) == CGSize(width: 1920, height: 1080))
    }

    @Test func muteRemovesTheSound() async throws {
        let clip = try await PresetMedia.busyClip()
        #expect(try await !AVURLAsset(url: clip).loadTracks(withMediaType: .audio).isEmpty)
        let (output, result) = try await edit(clip, from: .mov, to: .mp4, VideoEdits(trimEnd: 3, mute: true))
        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(abs(try await asset.load(.duration).seconds - 3) <= 0.1)
        #expect(result.notes.contains(.muted))
    }

    @Test func resizeKeepsTheAspectRatio() async throws {
        let clip = try await PresetMedia.busyClip()
        let (output, _) = try await edit(clip, from: .mov, to: .m4v, VideoEdits(maxPixelSize: 640))
        #expect(try await PresetMedia.size(of: output) == CGSize(width: 640, height: 360))
        #expect(FileFormat.detect(at: output)?.family == .video)
    }

    @Test func impossibleTargetIsRefusedBeforeEncoding() async throws {
        let clip = try await PresetMedia.busyClip()
        let started = Date()
        await #expect(throws: ConversionError.self) {
            _ = try await edit(clip, from: .mov, to: .mp4, VideoEdits(targetBytes: 100_000))
        }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func smallEnoughFilesAreKept() async throws {
        let clip = try await Media.clip(in: directory, withAudio: false)
        let (output, result) = try await edit(clip, from: .mp4, to: .mp4, VideoEdits(targetBytes: 25_000_000))
        #expect(try Data(contentsOf: output) == Data(contentsOf: clip))
        #expect(result.notes == [.alreadySmallEnough])
    }

    // MARK: Photos

    @Test("Photo presets meet their byte targets", arguments: [2_000_000, 200_000, 50_000])
    func photoTargets(target: Int) throws {
        let photo = try PresetMedia.busyJPEG(width: 4000, height: 3000)
        let request = ConversionRequest(source: .jpeg, target: .jpeg, options: ConversionOptions(image: ImageEdits(targetBytes: target)))
        let (data, result) = try ImageConverter.convert(photo, request: request)
        print("photo target \(target): \(photo.count) -> \(data.count) \(result.notes.map(\.rawValue))")
        #expect(data.count <= target)
    }
}

/// The FFmpeg helper honours the same edits for MKV, WebM and AVI.
@Suite("FFmpeg video edits", .serialized,
       .enabled(if: FFmpegHelper.url != nil, "ameya-ffmpeg not found: run scripts/build-ffmpeg.sh or set AMEYA_FFMPEG"))
struct FFmpegEditTests {
    let directory: URL
    let helper: URL

    init() throws {
        helper = try #require(FFmpegHelper.url)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-ffedit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func mkv() async throws -> URL {
        let output = directory.appendingPathComponent("busy.mkv")
        if !FileManager.default.fileExists(atPath: output.path) {
            try await FFmpegConverter.convert(input: try await PresetMedia.busyClip(), to: .mkv, output: output, helper: helper) { _ in }
        }
        return output
    }

    func edit(_ input: URL, from source: FileFormat, to target: FileFormat, _ edits: VideoEdits) async throws -> (URL, [ConversionNote]) {
        let output = directory.appendingPathComponent("out-\(UUID().uuidString).\(target.preferredExtension)")
        let notes = try await FFmpegConverter.edit(input: input, from: source, to: target, output: output, helper: helper, edits: edits) { _ in }
        return (output, notes)
    }

    @Test func sameFormatTrimAndMute() async throws {
        let (output, notes) = try await edit(try await mkv(), from: .mkv, to: .mkv, VideoEdits(trimStart: 1, trimEnd: 4, mute: true))
        let probe = try await FFmpegConverter.probe(output, helper: helper)
        #expect(probe.audio == nil && probe.video != nil)
        #expect(abs((probe.duration ?? 0) - 3) <= 0.1, "got \(probe.duration ?? 0) s")
        #expect(notes.contains(.trimmed) && notes.contains(.muted))
    }

    @Test func webmSizeTargetAndResize() async throws {
        let (output, notes) = try await edit(try await mkv(), from: .mkv, to: .webm, VideoEdits(maxPixelSize: 640, targetBytes: 2_000_000))
        let probe = try await FFmpegConverter.probe(output, helper: helper)
        print("ffmpeg webm 2 MB: \(VideoEditor.fileSize(output)) \(notes.map(\.rawValue))")
        #expect(VideoEditor.fileSize(output) <= 2_000_000)
        #expect(probe.video.flatMap(FFmpegConverter.dimensions(of:)).map { [$0.0, $0.1] } == [640, 360])
        #expect(probe.video?.codec == "vp9" && probe.audio?.codec == "opus")
    }

    @Test func mkvToMP4UnderTarget() async throws {
        let (output, notes) = try await edit(try await mkv(), from: .mkv, to: .mp4, VideoEdits(targetBytes: 5_000_000))
        print("ffmpeg mkv->mp4 5 MB: \(VideoEditor.fileSize(output)) \(notes.map(\.rawValue))")
        #expect(VideoEditor.fileSize(output) <= 5_000_000)
        #expect(FileFormat.detect(at: output) == .mp4)
    }

    @Test func aviResize() async throws {
        let (output, _) = try await edit(try await mkv(), from: .mkv, to: .avi, VideoEdits(trimEnd: 2, maxPixelSize: 480))
        let probe = try await FFmpegConverter.probe(output, helper: helper)
        #expect(probe.video.flatMap(FFmpegConverter.dimensions(of:)).map { [$0.0, $0.1] } == [480, 270])
    }
}

@Suite("FFmpeg edit arguments")
struct FFmpegEditArgumentTests {
    @Test func trimMuteScaleAndBitrate() throws {
        let probe = FFmpegConverter.parseProbe("""
          Duration: 00:00:10.00, start: 0.000000, bitrate: 1200 kb/s
          Stream #0:0: Video: h264 (High), yuv420p, 1920x1080, 30 fps
          Stream #0:1: Audio: aac (LC), 44100 Hz, stereo, fltp
        """)
        let plan = VideoBudget.Plan(videoBitrate: 1_000_000, audioBitrate: 96_000, longSide: 1280)
        let input = URL(fileURLWithPath: "/tmp/in.mkv"), output = URL(fileURLWithPath: "/tmp/out.mkv")
        let args = try FFmpegConverter.editArguments(probe, to: .mkv, input: input, output: output,
                                                     window: (2, 5), mute: false, plan: plan, allowCopy: true)
        let text = args.joined(separator: " ")
        #expect(text.contains("-ss 2.000 -i /tmp/in.mkv -t 3.000"))
        #expect(text.contains("-b:v 1000000") && text.contains("-b:a 96000") && text.contains("min(1280,iw)"))
        let muted = try FFmpegConverter.editArguments(probe, to: .mkv, input: input, output: output,
                                                      window: nil, mute: true, plan: nil, allowCopy: true)
        #expect(muted.contains("-an") && muted.joined(separator: " ").contains("-c:v copy") && !muted.contains("-ss"))
    }
}

// MARK: PDF

@Suite("PDF compress")
@MainActor
struct PDFCompressTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-pdfc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func compress(_ pdf: Data, targetBytes: Int? = nil) throws -> (Data, ConversionResult) {
        let input = directory.appendingPathComponent("in-\(UUID().uuidString).pdf")
        try pdf.write(to: input)
        let scratch = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let request = ConversionRequest(source: .pdf, target: .pdf,
                                        options: ConversionOptions(pdf: .compress(quality: 0.7, targetBytes: targetBytes)))
        let (outputs, result) = try PDFTools.run(request.options.pdf!, inputs: [input], request: request, scratch: scratch) { _ in }
        return (try Data(contentsOf: outputs[0]), result)
    }

    @Test func scannedPagesShrinkAndTextPagesStayText() throws {
        let original = try PresetMedia.pdf(scans: 3, textPages: 1)
        let (data, result) = try compress(original)
        print("pdf compress: \(original.count) -> \(data.count) \(result.notes.map(\.rawValue))")
        #expect(data.count < original.count / 2)
        #expect(result.notes == [.pdfPagesRecompressed])
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 4)
        #expect((document.page(at: 3)?.string ?? "").contains("Quarterly"))
        #expect(String(decoding: data, as: UTF8.self).contains("DCTDecode"))
    }

    @Test func textPDFIsNeverMadeBigger() throws {
        let original = try PresetMedia.pdf(scans: 0, textPages: 3)
        let (data, result) = try compress(original)
        #expect(data == original)
        #expect(result.notes == [.alreadySmallEnough])
    }

    @Test func sizeTargetStepsDown() throws {
        let original = try PresetMedia.pdf(scans: 2, textPages: 0)
        let (first, _) = try compress(original)
        let (data, result) = try compress(original, targetBytes: first.count / 2)
        print("pdf target \(first.count / 2): \(data.count) \(result.notes.map(\.rawValue))")
        #expect(data.count <= first.count / 2 || result.notes.contains(.targetSizeNotReached))
        #expect(data.count < first.count)
    }
}
