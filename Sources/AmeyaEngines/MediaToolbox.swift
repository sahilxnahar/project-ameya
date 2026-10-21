import AmeyaCore
@preconcurrency import AVFoundation
import Foundation

/// Runs the audio and video tools (`ConversionOptions.media`). Each tool lives in its own file:
/// AudioTools (volume, fades, trim, speed, channels, join, ringtone), Audiobook, VideoJoiner,
/// GIFAndFrames, SubtitleBurner and AudioVisualiser.
///
/// Inputs AVFoundation can't read (Ogg, Opus, MKV, WebM, …) are first decoded with the bundled
/// FFmpeg helper: sound to FLAC, video to MP4.
public enum MediaToolbox {
    @MainActor
    public static func run(
        _ tool: MediaTool, inputs: [URL], request: ConversionRequest, scratch: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (outputs: [URL], result: ConversionResult) {
        let formats = request.inputs ?? [request.source ?? inputs.first.flatMap(FileFormat.detect(at:)) ?? .other]
        guard formats.count == inputs.count, !inputs.isEmpty else { throw ConversionError.invalidData("the files didn't arrive") }
        let target = request.target
        let output = scratch.appendingPathComponent("output.\(target.preferredExtension)")
        let job = Job(target: target, output: output, scratch: scratch, progress: progress)
        var notes: [ConversionNote] = []
        var outputs = [output]
        var names: [String]?

        func readable(_ index: Int) async throws -> URL {
            try await prepare(inputs[index], format: formats[index], scratch: scratch, index: index)
        }
        func single() async throws -> (URL, FileFormat) {
            guard inputs.count == 1 else { throw ConversionError.invalidData("this tool takes one file at a time") }
            return (try await readable(0), formats[0])
        }

        switch tool {
        case .evenVolume(let loudness):
            let (input, format) = try await single()
            notes = try await AudioTools.evenVolume(input, isVideo: format.family == .video, to: loudness, job: job)
        case .fade(let fadeIn, let fadeOut):
            let (input, format) = try await single()
            notes = try await AudioTools.fade(input, isVideo: format.family == .video, fadeIn: fadeIn, fadeOut: fadeOut, job: job)
        case .trimAudio(let start, let end):
            notes = try await AudioTools.trim(try await single().0, start: start, end: end, job: job)
        case .speed(let factor):
            let (input, format) = try await single()
            notes = try await AudioTools.speed(input, isVideo: format.family == .video, factor: factor, job: job)
        case .channels(let mix):
            let (input, format) = try await single()
            notes = try await AudioTools.channels(input, isVideo: format.family == .video, mix: mix, job: job)
        case .ringtone(let start, let seconds):
            notes = try await AudioTools.ringtone(try await single().0, start: start, seconds: seconds, job: job)
        case .joinAudio:
            var files: [URL] = []
            for index in inputs.indices { files.append(try await readable(index)) }
            notes = try await AudioTools.join(files, job: job)
        case .joinVideos:
            var files: [URL] = []
            for index in inputs.indices { files.append(try await readable(index)) }
            notes = try await VideoJoiner.join(files, job: job)
        case .audiobook(let title, let chapterTitles):
            var sounds: [URL] = []
            var cover: URL?
            for index in inputs.indices {
                if formats[index].family == .image { cover = cover ?? inputs[index] } else { sounds.append(try await readable(index)) }
            }
            var titles = chapterTitles
            if titles.count != sounds.count { titles = sounds.indices.map { "Chapter \($0 + 1)" } }
            notes = try await Audiobook.make(sounds, titles: titles, title: title, cover: cover, job: job)
        case .gif(let targetBytes):
            notes = try await GIFAndFrames.gif(try await single().0, targetBytes: targetBytes, job: job)
        case .extractFrames(let interval, let format):
            let (files, frameNames, frameNotes) = try await GIFAndFrames.frames(try await single().0, every: interval,
                                                                                 format: format, maxFrames: request.options.maxFrames, job: job)
            outputs = files
            names = frameNames
            notes = frameNotes
        case .burnSubtitles:
            guard inputs.count == 2,
                  let video = formats.firstIndex(where: { $0.family == .video }),
                  let subtitle = formats.firstIndex(where: { $0.family == .subtitle }) else {
                throw ConversionError.refused("Add one video and one subtitle file (such as SRT or VTT).")
            }
            let cues = try SubtitleBurner.cues(from: inputs[subtitle], format: formats[subtitle])
            notes = try await SubtitleBurner.burn(cues, into: try await readable(video), job: job)
        case .autoCaption:
            let (input, _) = try await single()
            let cues = try await SubtitleBurner.transcribe(input, language: request.options.language, job: job)
            notes = try await SubtitleBurner.burn(cues, into: input, job: job.slice(from: 0.6)) + [.transcribedOnDevice]
        case .visualiser(let style, let background):
            notes = try await AudioVisualiser.make(try await single().0, style: style, background: background, job: job)
        }

        progress(1)
        let bytes = outputs.reduce(0) { $0 + VideoEditor.fileSize($1) }
        return (outputs, ConversionResult(outputBytes: bytes, frames: outputs.count, notes: notes, outputNames: names))
    }

    /// Where a tool writes and how it reports progress.
    struct Job: Sendable {
        let target: FileFormat
        let output: URL
        let scratch: URL
        let progress: @Sendable (Double) -> Void

        /// A scratch file that no other step uses.
        func temporary(_ name: String) -> URL { scratch.appendingPathComponent("\(UUID().uuidString)-\(name)") }

        /// The same job reporting into `lower…upper` of the bar.
        func slice(from lower: Double, to upper: Double = 1) -> Job {
            let report = progress
            return Job(target: target, output: output, scratch: scratch) { report(lower + (upper - lower) * min(max($0, 0), 1)) }
        }
    }

    /// A copy of `input` AVFoundation can read.
    static func prepare(_ input: URL, format: FileFormat, scratch: URL, index: Int) async throws -> URL {
        guard format.isFFmpegOnly else { return input }
        guard let helper = FFmpegAvailability.helperURL else {
            throw ConversionError.refused("\(format.displayName) files need the FFmpeg helper, which isn't installed in this copy of Ameya.")
        }
        let target: FileFormat = format.family == .video ? .mp4 : .flac
        let output = scratch.appendingPathComponent("readable-\(index).\(target.preferredExtension)")
        try await FFmpegConverter.convert(input: input, to: target, output: output, helper: helper) { _ in }
        return output
    }

    /// Puts `audio` (an AAC file) with the picture of `video` into `output`, copying both streams.
    static func mux(video: URL, audio: URL, target: FileFormat, output: URL) async throws {
        guard let fileType = VideoConverter.fileType(for: target) else { throw ConversionError.unsupportedTarget(target) }
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        guard let picture = try await videoAsset.loadTracks(withMediaType: .video).first else { throw ConversionError.noVideoTrack }
        guard let sound = try await audioAsset.loadTracks(withMediaType: .audio).first else { throw ConversionError.noAudioTrack }
        let pictureRange = try await picture.load(.timeRange)
        let soundRange = try await sound.load(.timeRange)
        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try videoTrack?.insertTimeRange(CMTimeRange(start: pictureRange.start, duration: pictureRange.duration), of: picture, at: .zero)
        videoTrack?.preferredTransform = try await picture.load(.preferredTransform)
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        try audioTrack?.insertTimeRange(soundRange, of: sound, at: .zero)
        try await export(composition, preset: AVAssetExportPresetPassthrough, fileType: fileType, to: output)
    }

    /// Exports with a system preset, falling back to re-encoding when the streams can't be copied.
    static func export(
        _ asset: AVAsset, preset: String, fileType: AVFileType, to output: URL,
        videoComposition: AVVideoComposition? = nil, pitch: AVAudioTimePitchAlgorithm? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        for candidate in [preset, AVAssetExportPresetHighestQuality] {
            try? FileManager.default.removeItem(at: output)
            guard let session = AVAssetExportSession(asset: asset, presetName: candidate),
                  session.supportedFileTypes.contains(fileType) else { continue }
            session.outputURL = output
            session.outputFileType = fileType
            session.shouldOptimizeForNetworkUse = true
            if let videoComposition { session.videoComposition = videoComposition }
            if let pitch { session.audioTimePitchAlgorithm = pitch }
            let box = SessionHolder(session)
            let poller = Task {
                while !Task.isCancelled {
                    progress(Double(box.session.progress) * 0.99)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            await box.session.export()
            poller.cancel()
            if box.session.status == .completed { return }
            if candidate == AVAssetExportPresetHighestQuality || preset == AVAssetExportPresetHighestQuality {
                throw ConversionError.mediaFailed(box.session.error?.localizedDescription ?? "the video couldn't be exported")
            }
        }
        throw ConversionError.unsupportedTarget(.mp4)
    }
}

/// AVAssetExportSession isn't Sendable; the poller only reads `progress`, which is thread-safe.
final class SessionHolder: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
