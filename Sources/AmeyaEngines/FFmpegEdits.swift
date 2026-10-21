import AmeyaCore
import Foundation

/// `VideoEdits` (trim, mute, resize, size target) for videos the FFmpeg helper reads or writes:
/// MKV, WebM, AVI, and FLV/WMV/MPEG-TS/MPEG sources. Same plan as `VideoEditor` (`VideoBudget`).
extension FFmpegConverter {
    static func edit(
        input: URL, from source: FileFormat, to target: FileFormat, output: URL, helper: URL,
        edits: VideoEdits, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [ConversionNote] {
        let probe = try await probe(input, helper: helper)
        guard let video = probe.video else { throw ConversionError.noVideoTrack }
        guard let duration = probe.duration, duration > 0 else {
            throw ConversionError.mediaFailed("the video's length couldn't be read")
        }
        progress(0.03)
        let window = try VideoBudget.window(edits, duration: duration)
        let trimmed = VideoBudget.isTrimmed(window, duration: duration)
        let (width, height) = dimensions(of: video) ?? (1280, 720)
        let fps = frameRate(of: video) ?? 30
        let resizes = edits.maxPixelSize.map { $0 < max(width, height) } ?? false

        var notes: [ConversionNote] = []
        if trimmed { notes.append(.trimmed) }
        if edits.mute { notes.append(.muted) }
        if let targetBytes = edits.targetBytes, !trimmed, !edits.mute, !resizes,
           VideoEditor.fileSize(input) <= targetBytes, source == target {
            try FileManager.default.copyItem(at: input, to: output)
            progress(1)
            return [.alreadySmallEnough]
        }

        // A trim re-encodes too: copied streams can only start on a keyframe, seconds off.
        let reencode = edits.targetBytes != nil || resizes || trimmed
        var plan = reencode ? try VideoBudget.plan(
            targetBytes: edits.targetBytes, seconds: window.end - window.start,
            hasAudio: probe.audio != nil && !edits.mute, width: width, height: height,
            fps: fps, maxPixelSize: edits.maxPixelSize
        ) : nil
        if edits.targetBytes != nil || resizes { notes.append(.videoMadeSmaller) }

        let seconds = window.end - window.start
        let share = edits.targetBytes == nil ? 1.0 : 0.9
        func attempt(_ plan: VideoBudget.Plan?, to file: URL, from low: Double, to high: Double) async throws {
            let reporter: @Sendable (String) -> Void = { line in
                guard line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst(12)) else { return }
                progress(low + (high - low) * min(1, max(0, micros / 1_000_000 / seconds)))
            }
            var args = try editArguments(probe, to: target, input: input, output: file, window: trimmed ? window : nil,
                                         mute: edits.mute, plan: plan, allowCopy: true)
            var run = try await execute(helper, args, onLine: reporter)
            if run.status != 0, args.contains("copy") {
                try? FileManager.default.removeItem(at: file)
                args = try editArguments(probe, to: target, input: input, output: file, window: trimmed ? window : nil,
                                         mute: edits.mute, plan: plan, allowCopy: false)
                run = try await execute(helper, args, onLine: reporter)
            }
            guard run.status == 0 else { throw error(from: run.stderr) }
            guard VideoEditor.fileSize(file) > 0 else { throw ConversionError.mediaFailed("no output was produced") }
        }

        try await attempt(plan, to: output, from: 0.03, to: share)
        if let targetBytes = edits.targetBytes, let first = plan, VideoEditor.fileSize(output) > targetBytes {
            plan = VideoBudget.retry(first, actualBytes: VideoEditor.fileSize(output), targetBytes: targetBytes,
                                     width: width, height: height, fps: fps)
            let second = output.deletingLastPathComponent().appendingPathComponent("smaller-\(output.lastPathComponent)")
            try await attempt(plan, to: second, from: share, to: 0.99)
            if VideoEditor.fileSize(second) < VideoEditor.fileSize(output) {
                try FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: second, to: output)
            } else {
                try? FileManager.default.removeItem(at: second)
            }
            if VideoEditor.fileSize(output) > targetBytes { notes.append(.targetSizeNotReached) }
        }
        progress(1)
        return notes
    }

    /// Arguments for an edit. With a `plan` the video is re-encoded at its bitrate and size (and the
    /// sound at its bitrate); without one, streams are copied where the container allows.
    static func editArguments(
        _ probe: Probe, to target: FileFormat, input: URL, output: URL,
        window: (start: Double, end: Double)?, mute: Bool, plan: VideoBudget.Plan?, allowCopy: Bool
    ) throws -> [String] {
        guard let video = probe.video else { throw ConversionError.noVideoTrack }
        guard let container = videoPlan(for: target, probe: probe) else { throw ConversionError.unsupportedTarget(target) }
        func seconds(_ value: Double) -> String { String(format: "%.3f", value) }

        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1", "-y"]
        if let window, window.start > 0 { args += ["-ss", seconds(window.start)] } // before -i: fast, and exact when re-encoding
        args += ["-i", input.path]
        if let window { args += ["-t", seconds(window.end - window.start)] }
        args += ["-sn", "-dn", "-max_muxing_queue_size", "4096", "-map", "0:\(video.index)"]

        if let plan {
            args += bitrateEncoder(for: target, bitrate: plan.videoBitrate)
            args += ["-vf", scaleFilter(longSide: plan.longSide)]
        } else if allowCopy, container.copy.contains(video.codec) {
            args += ["-c:v", "copy"]
            if video.codec == "hevc", [.mp4, .m4v, .mov].contains(target) { args += ["-tag:v", "hvc1"] }
        } else {
            args += container.encode + ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
        }

        if mute || probe.audio == nil {
            args += ["-an"]
        } else if let audio = probe.audio {
            args += ["-map", "0:\(audio.index)"]
            if let plan, plan.audioBitrate > 0 {
                args += ["-c:a", audioEncoder(for: target), "-b:a", String(plan.audioBitrate), "-ac", "2"]
            } else if allowCopy, container.audio.copy.contains(audio.codec) {
                args += ["-c:a", "copy"]
            } else {
                let stereo = audio.details.contains("mono") || audio.details.contains("stereo")
                args += container.audio.encode + (stereo ? [] : ["-ac", "2"])
            }
        }
        return args + container.extra + ["-f", container.audio.muxer, output.path]
    }

    /// The target's video encoder at an average bitrate, with peaks capped so short clips stay on budget.
    static func bitrateEncoder(for target: FileFormat, bitrate: Int) -> [String] {
        let rate = [String(bitrate), "-maxrate", String(bitrate * 3 / 2), "-bufsize", String(bitrate * 2)]
        switch target {
        case .webm:
            return ["-c:v", "libvpx-vp9", "-b:v"] + rate
                + ["-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-pix_fmt", "yuv420p"]
        case .avi:
            return ["-c:v", "mpeg4", "-b:v"] + rate + ["-tag:v", "XVID", "-pix_fmt", "yuv420p"]
        default:
            return ["-c:v", "h264_videotoolbox", "-allow_sw", "1", "-profile:v", "high", "-b:v", String(bitrate),
                    "-pix_fmt", "yuv420p"]
        }
    }

    static func audioEncoder(for target: FileFormat) -> String {
        switch target {
        case .webm: "libopus"
        case .avi: "libmp3lame"
        default: "aac"
        }
    }

    /// Fits the longest side to `longSide` (never enlarging), keeping the aspect ratio and even sizes.
    /// FFmpeg rotates phone videos upright first, so `iw`/`ih` are the upright size.
    static func scaleFilter(longSide: Int) -> String {
        let fit = "trunc(min(\(longSide),iw)/2)*2"
        let fitHeight = "trunc(min(\(longSide),ih)/2)*2"
        return "scale=w='if(gte(iw,ih),\(fit),-2)':h='if(gte(iw,ih),-2,\(fitHeight))'"
    }

    /// "1920x1080" in a stream description.
    static func dimensions(of stream: Probe.Stream) -> (Int, Int)? {
        guard let match = stream.details.firstMatch(of: /(\d{2,5})x(\d{2,5})/),
              let width = Int(match.1), let height = Int(match.2) else { return nil }
        return (width, height)
    }

    static func frameRate(of stream: Probe.Stream) -> Double? {
        guard let match = stream.details.firstMatch(of: /(\d+(?:\.\d+)?) fps/), let value = Double(match.1), value > 0 else {
            return nil
        }
        return min(value, 120)
    }
}
