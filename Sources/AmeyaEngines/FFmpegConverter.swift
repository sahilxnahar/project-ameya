import AmeyaCore
import Foundation

/// Converts Ogg, Opus, MP3 (writing), MKV, WebM, AVI and other non-Apple media by running the
/// bundled LGPL FFmpeg build (`ameya-ffmpeg`) as a child process of the worker.
///
/// The helper only ever sees two paths inside the worker's private scratch folder, inherits the
/// worker's sandbox, has no network code, and is killed together with the worker (same process group).
/// Streams are copied when the target container accepts the source codec, and re-encoded otherwise.
enum FFmpegConverter {
    /// What the helper reports about a source file.
    struct Probe: Equatable {
        struct Stream: Equatable {
            var index: Int
            var codec: String
            /// The rest of FFmpeg's description, e.g. "44100 Hz, stereo, s16".
            var details: String
        }
        var duration: Double?
        var video: Stream?
        var audio: Stream?
    }

    static func convert(
        input: URL,
        to target: FileFormat,
        output: URL,
        helper: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let probe = try await probe(input, helper: helper)
        progress(0.03)
        let reporter: @Sendable (String) -> Void = { line in
            guard let duration = probe.duration, duration > 0,
                  line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst(12)) else { return }
            progress(min(0.99, max(0.03, micros / 1_000_000 / duration)))
        }

        var arguments = try arguments(for: probe, to: target, input: input, output: output, allowCopy: true)
        var run = try await execute(helper, arguments, onLine: reporter)
        if run.status != 0, arguments.contains("copy") {
            // Some streams can't be copied cleanly (odd timestamps, missing headers); re-encode them.
            try? FileManager.default.removeItem(at: output)
            arguments = try self.arguments(for: probe, to: target, input: input, output: output, allowCopy: false)
            run = try await execute(helper, arguments, onLine: reporter)
        }
        guard run.status == 0 else { throw error(from: run.stderr) }
        guard let size = try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int, size > 0 else {
            throw ConversionError.mediaFailed("no output was produced")
        }
        progress(1)
    }

    // MARK: Probing

    static func probe(_ input: URL, helper: URL) async throws -> Probe {
        // Without an output FFmpeg prints the input's description and exits with status 1.
        let run = try await execute(helper, ["-hide_banner", "-nostdin", "-i", input.path], onLine: { _ in })
        if run.stderr.contains("Invalid data found when processing input") || !run.stderr.contains("Input #0") {
            throw ConversionError.unreadable
        }
        return parseProbe(run.stderr)
    }

    static func parseProbe(_ text: String) -> Probe {
        var probe = Probe()
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Duration:"), probe.duration == nil {
                probe.duration = parseDuration(line)
            }
            guard line.hasPrefix("Stream #0:"), !line.contains("(attached pic)"),
                  let match = line.firstMatch(of: streamPattern),
                  let index = Int(match.1) else { continue }
            let stream = Probe.Stream(index: index, codec: String(match.3), details: String(line[match.range.upperBound...]))
            if match.2 == "Video", probe.video == nil { probe.video = stream }
            if match.2 == "Audio", probe.audio == nil { probe.audio = stream }
        }
        return probe
    }

    /// "Stream #0:1[0x2](eng): Audio: aac (LC) ..." → index, kind, codec.
    nonisolated(unsafe) private static let streamPattern = /Stream #0:(\d+)[^:]*: (Video|Audio): ([A-Za-z0-9_]+)/

    private static func parseDuration(_ line: String) -> Double? {
        guard let match = line.firstMatch(of: /Duration: (\d+):(\d+):(\d+(?:\.\d+)?)/),
              let hours = Double(match.1), let minutes = Double(match.2), let seconds = Double(match.3) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    // MARK: Choosing codecs

    struct AudioPlan {
        var copy: Set<String>
        var encode: [String]
        var muxer: String
    }

    struct VideoPlan {
        var copy: Set<String>
        var encode: [String]
        var audio: AudioPlan
        var extra: [String] = []
    }

    static func audioPlan(for target: FileFormat, highBitDepth: Bool) -> AudioPlan? {
        let pcm = highBitDepth ? "24" : "16"
        switch target {
        case .mp3: return AudioPlan(copy: ["mp3"], encode: ["-c:a", "libmp3lame", "-q:a", "2"], muxer: "mp3")
        case .ogg: return AudioPlan(copy: ["vorbis"], encode: ["-c:a", "libvorbis", "-q:a", "5"], muxer: "ogg")
        case .opus: return AudioPlan(copy: ["opus"], encode: ["-c:a", "libopus", "-b:a", "128k"], muxer: "opus")
        case .m4a: return AudioPlan(copy: ["aac"], encode: ["-c:a", "aac", "-b:a", "256k"], muxer: "ipod")
        case .alac: return AudioPlan(copy: ["alac"], encode: ["-c:a", "alac"], muxer: "ipod")
        case .wav: return AudioPlan(copy: [], encode: ["-c:a", "pcm_s\(pcm)le"], muxer: "wav")
        case .aiff: return AudioPlan(copy: [], encode: ["-c:a", "pcm_s\(pcm)be"], muxer: "aiff")
        case .caf: return AudioPlan(copy: [], encode: ["-c:a", "pcm_s\(pcm)le"], muxer: "caf")
        case .flac: return AudioPlan(copy: ["flac"], encode: ["-c:a", "flac"], muxer: "flac")
        default: return nil
        }
    }

    static func videoPlan(for target: FileFormat, probe: Probe) -> VideoPlan? {
        let aac = AudioPlan(copy: ["aac"], encode: ["-c:a", "aac", "-b:a", "192k"], muxer: "")
        let h264 = ["-c:v", "h264_videotoolbox", "-allow_sw", "1", "-profile:v", "high",
                    "-b:v", String(h264Bitrate(probe.video)), "-pix_fmt", "yuv420p"]
        switch target {
        case .webm:
            return VideoPlan(
                copy: ["vp8", "vp9", "av1"],
                encode: ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1",
                         "-deadline", "good", "-cpu-used", "4", "-pix_fmt", "yuv420p"],
                audio: AudioPlan(copy: ["opus", "vorbis"], encode: ["-c:a", "libopus", "-b:a", "128k"], muxer: "webm")
            )
        case .mkv:
            return VideoPlan(
                copy: ["h264", "hevc", "vp8", "vp9", "av1", "mpeg4", "mpeg1video", "mpeg2video", "theora", "vc1", "prores", "mjpeg"],
                encode: h264,
                audio: AudioPlan(copy: ["aac", "mp3", "mp2", "opus", "vorbis", "flac", "alac", "ac3", "eac3", "pcm_s16le", "pcm_s24le"],
                                 encode: aac.encode, muxer: "matroska")
            )
        case .avi:
            return VideoPlan(
                copy: ["mpeg4", "msmpeg4v3", "mjpeg"],
                encode: ["-c:v", "mpeg4", "-q:v", "3", "-tag:v", "XVID", "-pix_fmt", "yuv420p"],
                audio: AudioPlan(copy: ["mp3", "ac3", "pcm_s16le"], encode: ["-c:a", "libmp3lame", "-q:a", "2"], muxer: "avi")
            )
        case .mp4, .m4v:
            return VideoPlan(
                copy: ["h264", "hevc"], encode: h264,
                audio: AudioPlan(copy: ["aac", "alac"], encode: aac.encode, muxer: target == .mp4 ? "mp4" : "ipod"),
                extra: ["-movflags", "+faststart"]
            )
        case .mov:
            return VideoPlan(
                copy: ["h264", "hevc", "prores", "mjpeg"], encode: h264,
                audio: AudioPlan(copy: ["aac", "alac", "pcm_s16le", "pcm_s24le"], encode: aac.encode, muxer: "mov"),
                extra: ["-movflags", "+faststart"]
            )
        default:
            return nil
        }
    }

    /// Roughly 0.1 bits per pixel at the source frame rate, between 1 and 40 Mbit/s.
    static func h264Bitrate(_ video: Probe.Stream?) -> Int {
        var pixels = 1280 * 720
        var fps = 30.0
        if let details = video?.details {
            if let size = details.firstMatch(of: /(\d{2,5})x(\d{2,5})/), let w = Int(size.1), let h = Int(size.2) {
                pixels = w * h
            }
            if let rate = details.firstMatch(of: /(\d+(?:\.\d+)?) fps/), let value = Double(rate.1), value > 0 {
                fps = min(value, 120)
            }
        }
        return min(40_000_000, max(1_000_000, Int(Double(pixels) * fps * 0.1)))
    }

    static func arguments(for probe: Probe, to target: FileFormat, input: URL, output: URL, allowCopy: Bool) throws -> [String] {
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1", "-y",
                    "-i", input.path, "-sn", "-dn", "-max_muxing_queue_size", "4096"]

        func audioArgs(_ plan: AudioPlan, _ stream: Probe.Stream) -> [String] {
            if allowCopy, plan.copy.contains(stream.codec) { return ["-c:a", "copy"] }
            let layout = stream.details
            let downmix = layout.contains("mono") || layout.contains("stereo") ? [] : ["-ac", "2"]
            return plan.encode + downmix
        }

        switch target.family {
        case .audio:
            guard let audio = probe.audio else { throw ConversionError.noAudioTrack }
            let lossless = ["flac", "alac", "wavpack", "ape", "tta", "truehd"].contains(audio.codec) || audio.codec.hasPrefix("pcm_")
            let high = lossless && ["s24", "s32", "flt", "dbl"].contains { audio.details.contains($0) }
            guard let plan = audioPlan(for: target, highBitDepth: high) else { throw ConversionError.unsupportedTarget(target) }
            args += ["-map", "0:\(audio.index)", "-vn"] + audioArgs(plan, audio) + ["-f", plan.muxer]
        case .video:
            guard let video = probe.video else { throw ConversionError.noVideoTrack }
            guard let plan = videoPlan(for: target, probe: probe) else { throw ConversionError.unsupportedTarget(target) }
            args += ["-map", "0:\(video.index)"]
            if allowCopy, plan.copy.contains(video.codec) {
                args += ["-c:v", "copy"]
                if video.codec == "hevc", [.mp4, .m4v, .mov].contains(target) { args += ["-tag:v", "hvc1"] }
            } else {
                // Encoders want even dimensions.
                args += plan.encode + ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
            }
            if let audio = probe.audio {
                args += ["-map", "0:\(audio.index)"] + audioArgs(plan.audio, audio)
            }
            args += plan.extra + ["-f", plan.audio.muxer]
        default:
            throw ConversionError.unsupportedTarget(target)
        }
        return args + [output.path]
    }

    // MARK: Errors

    static func error(from stderr: String) -> ConversionError {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let text = lines.joined(separator: "\n")
        if text.contains("Invalid data found when processing input") { return .unreadable }
        if text.contains("matches no streams") { return .mediaFailed("the file has no stream that can be converted") }
        if text.contains("videotoolbox") || text.contains("VTCompressionSession") {
            return .mediaFailed("this Mac's video encoder couldn't encode the video")
        }
        if text.contains("Error while opening encoder") || text.contains("Error initializing output stream") {
            return .mediaFailed("the encoder couldn't start (\(lines.last ?? "unknown error"))")
        }
        if text.contains("No space left on device") { return .mediaFailed("the disk is full") }
        guard let last = lines.last else { return .mediaFailed("the media helper stopped unexpectedly") }
        return .mediaFailed(String(last.prefix(200)))
    }

    // MARK: Running the helper

    struct Run: Sendable {
        var status: Int32
        var stderr: String
    }

    /// Runs the helper, calling `onLine` for each line it prints on stdout, and collects stderr.
    static func execute(_ helper: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void) async throws -> Run {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = helper
                process.arguments = arguments
                process.environment = [:] // nothing from the worker's environment reaches the helper
                process.standardInput = FileHandle.nullDevice
                let stdout = Pipe(), stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ConversionError.mediaFailed("the media helper couldn't start"))
                    return
                }

                let errors = StderrBuffer()
                let errorHandle = stderr.fileHandleForReading
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    while case let chunk = errorHandle.availableData, !chunk.isEmpty { errors.append(chunk) }
                    group.leave()
                }

                var pending = Data()
                let outputHandle = stdout.fileHandleForReading
                while case let chunk = outputHandle.availableData, !chunk.isEmpty {
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        onLine(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                        pending.removeSubrange(pending.startIndex...newline)
                    }
                }
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: Run(status: process.terminationStatus, stderr: errors.text))
            }
        }
    }
}

/// Keeps the last 64 KB of the helper's error output.
private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > 65_536 { data = data.suffix(65_536) }
        }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
