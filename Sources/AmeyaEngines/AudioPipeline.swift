import AmeyaCore
@preconcurrency import AVFoundation
import Foundation

/// Streams the sound of an asset (a file or a composition) as float PCM, one array per channel,
/// through processors, into an audio file. Used by the audio and video tools (MediaToolbox).
enum AudioPipeline {
    typealias Chunk = [[Float]]

    struct Layout {
        var sampleRate: Double
        var channels: Int
    }

    /// The source's sample rate and channel count (at most two), for the first audio track.
    static func layout(of asset: AVAsset, target: FileFormat) async throws -> Layout {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ConversionError.noAudioTrack }
        let source = try await AudioConverter.sourceDescription(of: track)
        return Layout(sampleRate: AudioConverter.targetSampleRate(source.sampleRate, for: target),
                      channels: Int(min(max(source.channels, 1), 2)))
    }

    /// Reads every audio track of `asset`, mixed, as `layout`. With `pitch`, a composition whose time
    /// has been scaled plays at the new speed with the pitch kept.
    static func read(
        _ asset: AVAsset, layout: Layout, timeRange: CMTimeRange? = nil,
        pitch: AVAudioTimePitchAlgorithm? = nil, progress: (Double) -> Void = { _ in },
        body: (Chunk) throws -> Void
    ) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ConversionError.noAudioTrack }
        let duration: Double
        if let timeRange { duration = timeRange.duration.seconds } else { duration = try await asset.load(.duration).seconds }
        let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: layout.sampleRate,
            AVNumberOfChannelsKey: layout.channels,
        ])
        if let pitch { output.audioTimePitchAlgorithm = pitch }
        guard reader.canAdd(output) else { throw ConversionError.mediaFailed("the sound can't be decoded") }
        reader.add(output)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: layout.sampleRate,
                                         channels: AVAudioChannelCount(layout.channels), interleaved: false) else {
            throw ConversionError.mediaFailed("unsupported channel layout")
        }
        guard reader.startReading() else {
            throw ConversionError.mediaFailed(reader.error?.localizedDescription ?? "couldn't start reading")
        }
        let start = timeRange?.start.seconds ?? 0
        var done = 0.0
        while let sample = output.copyNextSampleBuffer() {
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            buffer.frameLength = frames
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                                      into: buffer.mutableAudioBufferList)
            guard status == noErr else { throw ConversionError.mediaFailed("decoding error \(status)") }
            try body(chunk(from: buffer))
            done += Double(frames) / layout.sampleRate
            if duration > 0 { progress(min(1, max(done, CMSampleBufferGetPresentationTimeStamp(sample).seconds - start) / duration)) }
        }
        guard reader.status == .completed else {
            throw ConversionError.mediaFailed(reader.error?.localizedDescription ?? "reading stopped early")
        }
    }

    static func chunk(from buffer: AVAudioPCMBuffer) -> Chunk {
        let frames = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData else { return [] }
        return (0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }
    }

    /// Writes chunks to an audio file in `target`'s format (AAC, ALAC, WAV, AIFF, CAF or FLAC).
    final class FileSink {
        private let file: AVAudioFile
        private let format: AVAudioFormat
        let channels: Int

        init(output: URL, target: FileFormat, layout: Layout, bitRate: Int? = nil) throws {
            var settings = AudioConverter.fileSettings(for: target, sampleRate: layout.sampleRate,
                                                       channels: AVAudioChannelCount(layout.channels), bitDepth: 16)
            if target == .m4a {
                // AAC allows only so many bits per sample: keep low sample rates (22 kHz) valid.
                let ceiling = Int(layout.sampleRate * 2.5) * layout.channels
                settings[AVEncoderBitRateKey] = min(bitRate ?? (settings[AVEncoderBitRateKey] as? Int ?? 256_000), ceiling)
            }
            file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: layout.sampleRate,
                                             channels: AVAudioChannelCount(layout.channels), interleaved: false) else {
                throw ConversionError.mediaFailed("unsupported channel layout")
            }
            self.format = format
            channels = layout.channels
        }

        func write(_ chunk: Chunk) throws {
            guard let frames = chunk.first?.count, frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let data = buffer.floatChannelData else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<channels {
                let source = chunk[min(channel, chunk.count - 1)]
                source.withUnsafeBufferPointer { data[channel].update(from: $0.baseAddress!, count: frames) }
            }
            try file.write(from: buffer)
        }

        /// Closes the file, finishing its header. Writing afterwards is an error.
        func close() {
            if #available(macOS 15, *) { file.close() }
        }
    }

    /// Formats AVAudioFile can write. Anything else (MP3, Ogg, Opus) is written as FLAC first and
    /// converted with the FFmpeg helper.
    static func isNativeTarget(_ format: FileFormat) -> Bool {
        [.m4a, .alac, .wav, .aiff, .caf, .flac].contains(format)
    }
}

// MARK: Processors

/// One step in the chain: takes a chunk and returns the next (possibly delayed) chunk.
protocol PCMProcessor: AnyObject {
    func process(_ chunk: AudioPipeline.Chunk) -> AudioPipeline.Chunk
    /// Whatever is still held back at the end.
    func finish() -> AudioPipeline.Chunk
}

extension PCMProcessor {
    func finish() -> AudioPipeline.Chunk { [] }
}

extension PeakLimiter: PCMProcessor {}

/// A fixed gain, in dB.
final class GainStage: PCMProcessor {
    let gain: Float
    init(decibels: Double) { gain = Float(pow(10, decibels / 20)) }
    func process(_ chunk: AudioPipeline.Chunk) -> AudioPipeline.Chunk {
        gain == 1 ? chunk : chunk.map { $0.map { $0 * gain } }
    }
}

/// Fades in from silence and out to silence along a smooth S-curve.
final class FadeStage: PCMProcessor {
    private let total: Int
    private let fadeIn: Int
    private let fadeOut: Int
    private var position = 0

    init(totalFrames: Int, fadeInFrames: Int, fadeOutFrames: Int) {
        total = totalFrames
        fadeIn = min(fadeInFrames, totalFrames)
        fadeOut = min(fadeOutFrames, totalFrames)
    }

    static func curve(_ x: Double) -> Float { Float((1 - cos(Double.pi * min(max(x, 0), 1))) / 2) }

    func gain(at frame: Int) -> Float {
        var gain: Float = 1
        if fadeIn > 0, frame < fadeIn { gain = Self.curve(Double(frame) / Double(fadeIn)) }
        let remaining = total - frame
        if fadeOut > 0, remaining <= fadeOut { gain = min(gain, Self.curve(Double(max(remaining - 1, 0)) / Double(fadeOut))) }
        return gain
    }

    func process(_ chunk: AudioPipeline.Chunk) -> AudioPipeline.Chunk {
        guard let frames = chunk.first?.count else { return chunk }
        let gains = (0..<frames).map { gain(at: position + $0) }
        position += frames
        return chunk.map { samples in zip(samples, gains).map { $0 * $1 } }
    }
}

/// Mono, swapped or one-sided sound from a stereo chunk.
final class ChannelStage: PCMProcessor {
    let mix: ChannelMix
    init(_ mix: ChannelMix) { self.mix = mix }

    var outputChannels: Int { mix == .swap ? 2 : 1 }

    func process(_ chunk: AudioPipeline.Chunk) -> AudioPipeline.Chunk {
        guard chunk.count >= 2 else { return mix == .swap ? [chunk[0], chunk[0]] : chunk }
        switch mix {
        case .mono: return [zip(chunk[0], chunk[1]).map { ($0 + $1) / 2 }]
        case .swap: return [chunk[1], chunk[0]]
        case .leftOnly: return [chunk[0]]
        case .rightOnly: return [chunk[1]]
        }
    }
}

/// Lets through at most `frames` samples per channel, then nothing.
final class LengthLimit: PCMProcessor {
    private var remaining: Int
    init(frames: Int) { remaining = max(frames, 0) }
    func process(_ chunk: AudioPipeline.Chunk) -> AudioPipeline.Chunk {
        guard let count = chunk.first?.count else { return chunk }
        let keep = min(count, remaining)
        remaining -= keep
        return keep == count ? chunk : chunk.map { Array($0.prefix(keep)) }
    }
}

/// Measures what passes through without changing it.
final class MeterStage: PCMProcessor {
    let meter: LoudnessMeter
    init(sampleRate: Double, channels: Int) { meter = LoudnessMeter(sampleRate: sampleRate, channels: channels) }
    func process(_ chunk: AudioPipeline.Chunk) -> AudioPipeline.Chunk {
        meter.add(chunk)
        return chunk
    }
}

/// Runs processors in order, so a chain looks like one processor.
final class ProcessorChain: PCMProcessor {
    let stages: [PCMProcessor]
    init(_ stages: [PCMProcessor]) { self.stages = stages }

    func process(_ chunk: AudioPipeline.Chunk) -> AudioPipeline.Chunk {
        stages.reduce(chunk) { $1.process($0) }
    }

    func finish() -> AudioPipeline.Chunk {
        var tail: AudioPipeline.Chunk = []
        for stage in stages {
            var flushed = tail.isEmpty ? [] : stage.process(tail)
            let own = stage.finish()
            if flushed.isEmpty { flushed = own } else if !own.isEmpty {
                flushed = zip(flushed, own).map { $0 + $1 }
            }
            tail = flushed
        }
        return tail
    }
}
