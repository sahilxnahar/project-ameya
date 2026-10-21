import AmeyaCore
@preconcurrency import AVFoundation
import Foundation

/// Sound tools: even volume, fades, trim, speed, channels, join and ringtones. Audio files are
/// rewritten in the requested format; for videos only the sound is rewritten (as AAC) and the
/// picture is copied untouched.
enum AudioTools {
    typealias Job = MediaToolbox.Job
    typealias Layout = AudioPipeline.Layout

    // MARK: Even volume

    /// Ceiling for the limiter, a little under −1 dBTP so encoding can't push peaks over it.
    static func ceiling(lossy: Bool) -> Double { lossy ? LoudnessTarget.truePeakCeiling - 1.0 : LoudnessTarget.truePeakCeiling - 0.2 }

    static func evenVolume(_ input: URL, isVideo: Bool, to loudness: LoudnessTarget, job: Job) async throws -> [ConversionNote] {
        let asset = AVURLAsset(url: input)
        let soundFormat = isVideo ? FileFormat.m4a : job.target
        let layout = try await AudioPipeline.layout(of: asset, target: soundFormat)
        let meter = LoudnessMeter(sampleRate: layout.sampleRate, channels: layout.channels)
        try await AudioPipeline.read(asset, layout: layout, progress: { job.progress(0.3 * $0) }) { meter.add($0) }
        guard let measured = meter.integratedLoudness else {
            throw ConversionError.refused("This file is silent, so there's no volume to even out.")
        }
        let lossy = isVideo || [.m4a, .mp3, .ogg, .opus].contains(job.target)
        let ceilingDB = ceiling(lossy: lossy)
        func limiter() -> PeakLimiter {
            PeakLimiter(ceilingDB: ceilingDB, sampleRate: layout.sampleRate, channels: layout.channels)
        }

        // Limiting loud moments lowers the overall loudness a little. When the limiter works,
        // find the gain that still lands on the target with quick measuring-only passes
        // (secant steps), then write once.
        var gain = min(loudness.lufs - measured, 40)
        var previous: (gain: Double, result: Double)?
        for trial in 0..<6 {
            let stage = limiter()
            let check = MeterStage(sampleRate: layout.sampleRate, channels: layout.channels)
            let chain = ProcessorChain([GainStage(decibels: gain), stage, check])
            let share = 0.3 + 0.08 * Double(trial)
            try await AudioPipeline.read(asset, layout: layout, progress: { job.progress(share + 0.08 * $0) }) { _ = chain.process($0) }
            _ = chain.finish()
            guard stage.engaged, let result = check.meter.integratedLoudness else { break }
            let miss = loudness.lufs - result
            if abs(miss) <= 0.1 { break }
            var step = miss
            if let previous, abs(result - previous.result) > 0.01 {
                step = miss * (gain - previous.gain) / (result - previous.result)
            }
            previous = (gain, result)
            gain = min(gain + min(max(step, -12), 12), 40)
        }
        try await writeSound(asset, layout: layout, chain: ProcessorChain([GainStage(decibels: gain), limiter()]),
                             channels: layout.channels, source: input, isVideo: isVideo, job: job.slice(from: 0.78, to: 0.99))
        return [.volumeEvened]
    }

    // MARK: Fades, trim, channels, speed

    static func fade(_ input: URL, isVideo: Bool, fadeIn: Double, fadeOut: Double, job: Job) async throws -> [ConversionNote] {
        guard fadeIn > 0 || fadeOut > 0 else { throw ConversionError.refused("Choose how long the sound should fade in or out.") }
        let asset = AVURLAsset(url: input)
        let layout = try await AudioPipeline.layout(of: asset, target: isVideo ? .m4a : job.target)
        let duration = try await asset.load(.duration).seconds
        let total = Int(duration * layout.sampleRate)
        // Fades longer than the sound share it.
        let scale = min(1, duration / max(fadeIn + fadeOut, 0.001))
        let stage = FadeStage(totalFrames: total, fadeInFrames: Int(fadeIn * scale * layout.sampleRate),
                              fadeOutFrames: Int(fadeOut * scale * layout.sampleRate))
        try await writeSound(asset, layout: layout, chain: ProcessorChain([stage]), channels: layout.channels,
                             source: input, isVideo: isVideo, job: job)
        return [.fadedInOut]
    }

    /// Keeps `start…end` (seconds) of the sound.
    static func trim(_ input: URL, start: Double?, end: Double?, job: Job) async throws -> [ConversionNote] {
        let asset = AVURLAsset(url: input)
        let range = try await timeRange(of: asset, start: start ?? 0, end: end)
        let layout = try await AudioPipeline.layout(of: asset, target: job.target)
        try await writeSound(asset, layout: layout, timeRange: range, chain: ProcessorChain([]), channels: layout.channels,
                             source: input, isVideo: false, job: job)
        return [.soundTrimmed]
    }

    static func channels(_ input: URL, isVideo: Bool, mix: ChannelMix, job: Job) async throws -> [ConversionNote] {
        let asset = AVURLAsset(url: input)
        var layout = try await AudioPipeline.layout(of: asset, target: isVideo ? .m4a : job.target)
        layout.channels = 2 // a mono source is read as two equal sides
        let stage = ChannelStage(mix)
        try await writeSound(asset, layout: layout, chain: ProcessorChain([stage]), channels: stage.outputChannels,
                             source: input, isVideo: isVideo, job: job)
        switch mix {
        case .mono: return [.mixedToMono]
        case .swap: return [.channelsSwapped]
        case .leftOnly, .rightOnly: return [.oneSideKept]
        }
    }

    /// Faster or slower with the same pitch: the composition's time is scaled and AVFoundation's
    /// spectral time-stretch fills the gap.
    static func speed(_ input: URL, isVideo: Bool, factor: Double, job: Job) async throws -> [ConversionNote] {
        guard MediaTool.speedRange.contains(factor) else { throw ConversionError.refused("Choose a speed between 0.5× and 2×.") }
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration)
        let full = CMTimeRange(start: .zero, duration: duration)
        let composition = AVMutableComposition()
        let types: [AVMediaType] = isVideo ? [.video, .audio] : [.audio]
        for type in types {
            for track in try await asset.loadTracks(withMediaType: type) {
                let copy = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
                try copy?.insertTimeRange(full, of: track, at: .zero)
                if type == .video { copy?.preferredTransform = try await track.load(.preferredTransform) }
            }
        }
        guard !composition.tracks(withMediaType: .audio).isEmpty || isVideo else { throw ConversionError.noAudioTrack }
        let scaled = CMTimeMultiplyByFloat64(duration, multiplier: 1 / factor)
        composition.scaleTimeRange(full, toDuration: scaled)
        if isVideo {
            guard let fileType = VideoConverter.fileType(for: job.target) else { throw ConversionError.unsupportedTarget(job.target) }
            try await MediaToolbox.export(composition, preset: AVAssetExportPresetHighestQuality, fileType: fileType,
                                          to: job.output, pitch: .spectral, progress: job.progress)
        } else {
            let layout = try await AudioPipeline.layout(of: composition, target: job.target)
            // The time-stretcher can run on past the scaled end; stop exactly there.
            try await writeSound(composition, layout: layout, timeRange: CMTimeRange(start: .zero, duration: scaled), pitch: .spectral, chain: ProcessorChain([]),
                                 channels: layout.channels, source: input, isVideo: false, job: job)
        }
        return [.speedChanged]
    }

    // MARK: Ringtone

    static func ringtone(_ input: URL, start: Double, seconds: Double, job: Job) async throws -> [ConversionNote] {
        let length = min(max(seconds, 1), MediaTool.maxRingtoneSeconds)
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        guard start >= 0, start < duration - 0.5 else {
            throw ConversionError.refused("The start is after the end of the sound; choose an earlier start.")
        }
        let end = min(start + length, duration)
        let range = try await timeRange(of: asset, start: start, end: end)
        let layout = try await AudioPipeline.layout(of: asset, target: .m4a)
        let frames = Int((end - start) * layout.sampleRate)
        let fade = FadeStage(totalFrames: frames, fadeInFrames: Int(0.3 * layout.sampleRate), fadeOutFrames: Int(1.5 * layout.sampleRate))
        try await writeSound(asset, layout: layout, timeRange: range, chain: ProcessorChain([fade]), channels: layout.channels,
                             source: input, isVideo: false, format: .m4a, job: job)
        return end - start < length - 0.05 ? [.ringtoneShorter, .ringtoneHowTo] : [.ringtoneHowTo]
    }

    // MARK: Join

    static func join(_ files: [URL], job: Job) async throws -> [ConversionNote] {
        guard files.count >= 2 else { throw ConversionError.refused("Add at least two sound files to join.") }
        let (composition, _) = try await sequence(files)
        var layout = try await AudioPipeline.layout(of: AVURLAsset(url: files[0]), target: job.target)
        for file in files.dropFirst() {
            layout.channels = max(layout.channels, try await AudioPipeline.layout(of: AVURLAsset(url: file), target: job.target).channels)
        }
        try await writeSound(composition, layout: layout, chain: ProcessorChain([]), channels: layout.channels,
                             source: files[0], isVideo: false, job: job)
        return [.joinedInOrder]
    }

    /// The sound of every file, one after another, and where each one sits.
    static func sequence(_ files: [URL]) async throws -> (AVMutableComposition, [CMTimeRange]) {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ConversionError.mediaFailed("the sound couldn't be prepared")
        }
        var cursor = CMTime.zero
        var ranges: [CMTimeRange] = []
        for file in files {
            let asset = AVURLAsset(url: file)
            guard let sound = try await asset.loadTracks(withMediaType: .audio).first else {
                throw ConversionError.refused("“\(file.lastPathComponent)” has no sound to join.")
            }
            let range = try await sound.load(.timeRange)
            try track.insertTimeRange(range, of: sound, at: cursor)
            ranges.append(CMTimeRange(start: cursor, duration: range.duration))
            cursor = cursor + range.duration
        }
        return (composition, ranges)
    }

    // MARK: Shared

    /// `start…end` seconds as a time range inside the asset, checked.
    static func timeRange(of asset: AVAsset, start: Double, end: Double?) async throws -> CMTimeRange {
        let duration = try await asset.load(.duration).seconds
        let finish = min(end ?? duration, duration)
        guard start >= 0, start < duration else { throw ConversionError.refused("The start is after the end of the sound.") }
        guard finish > start else { throw ConversionError.refused("The end needs to be after the start.") }
        return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000),
                           end: CMTime(seconds: finish, preferredTimescale: 48_000))
    }

    /// Reads, processes and writes the sound. For a video, the new sound (AAC) is put back with the
    /// original picture; otherwise it is written as `format` (default: the job's target), through
    /// FFmpeg for MP3, Ogg and Opus.
    static func writeSound(
        _ asset: AVAsset, layout: Layout, timeRange: CMTimeRange? = nil, pitch: AVAudioTimePitchAlgorithm? = nil,
        chain: PCMProcessor, channels: Int, source: URL, isVideo: Bool, format: FileFormat? = nil,
        to destination: URL? = nil, bitRate: Int? = nil, job: Job
    ) async throws {
        let wanted = isVideo ? FileFormat.m4a : (format ?? job.target)
        let native = AudioPipeline.isNativeTarget(wanted)
        let finalURL = destination ?? job.output
        let file = isVideo ? job.temporary("sound.m4a") : native ? finalURL : job.temporary("sound.flac")
        do {
            let sink = try AudioPipeline.FileSink(output: file, target: native ? wanted : .flac,
                                                  layout: Layout(sampleRate: layout.sampleRate, channels: channels), bitRate: bitRate)
            try await AudioPipeline.read(asset, layout: layout, timeRange: timeRange, pitch: pitch,
                                         progress: { job.progress(0.95 * $0) }) { try sink.write(chain.process($0)) }
            try sink.write(chain.finish())
            sink.close()
        }
        if isVideo {
            try await MediaToolbox.mux(video: source, audio: file, target: job.target, output: finalURL)
        } else if !native {
            guard let helper = FFmpegAvailability.helperURL else { throw ConversionError.unsupportedTarget(wanted) }
            try await FFmpegConverter.convert(input: file, to: wanted, output: finalURL, helper: helper) { _ in }
        }
    }
}
