import AmeyaCore
@preconcurrency import AVFoundation
import Foundation

/// Converts the sound of any audio or video file to AAC, Apple Lossless, WAV, AIFF, CAF or FLAC.
///
/// The source is decoded to 32-bit float PCM (resampled and mixed down to at most two channels
/// by AVFoundation) and re-encoded by AVAudioFile, which picks the container from the extension.
enum AudioConverter {
    static func convert(
        input: URL,
        to target: FileFormat,
        output: URL,
        progress: (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.noAudioTrack
        }
        let duration = try await asset.load(.duration).seconds
        let source = try await sourceDescription(of: track)

        let sampleRate = targetSampleRate(source.sampleRate, for: target)
        let channels = AVAudioChannelCount(min(max(source.channels, 1), 2))
        let bitDepth = source.bitDepth > 16 ? 24 : 16

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ])
        guard reader.canAdd(readerOutput) else { throw ConversionError.mediaFailed("the sound can't be decoded") }
        reader.add(readerOutput)

        guard let processing = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false) else {
            throw ConversionError.mediaFailed("unsupported channel layout")
        }
        let settings = fileSettings(for: target, sampleRate: sampleRate, channels: channels, bitDepth: bitDepth)

        do {
            // Scoped so the file is closed (and its header finalised) before returning.
            let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard reader.startReading() else {
                throw ConversionError.mediaFailed(reader.error?.localizedDescription ?? "couldn't start reading")
            }
            while let sample = readerOutput.copyNextSampleBuffer() {
                let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
                guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: frames) else { continue }
                buffer.frameLength = frames
                let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
                guard status == noErr else { throw ConversionError.mediaFailed("decoding error \(status)") }
                try file.write(from: buffer)
                if duration > 0 {
                    progress(min(0.99, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration))
                }
            }
        }
        guard reader.status == .completed else {
            throw ConversionError.mediaFailed(reader.error?.localizedDescription ?? "reading stopped early")
        }
        progress(1)
    }

    struct SourceDescription {
        var sampleRate: Double
        var channels: UInt32
        var bitDepth: Int
    }

    static func sourceDescription(of track: AVAssetTrack) async throws -> SourceDescription {
        let descriptions = try await track.load(.formatDescriptions)
        guard let first = descriptions.first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee else {
            return SourceDescription(sampleRate: 44_100, channels: 2, bitDepth: 16)
        }
        let isFloat = basic.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let depth = isFloat ? 32 : Int(basic.mBitsPerChannel)
        return SourceDescription(
            sampleRate: basic.mSampleRate > 0 ? basic.mSampleRate : 44_100,
            channels: basic.mChannelsPerFrame,
            bitDepth: depth > 0 ? depth : 16
        )
    }

    /// AAC tops out at 48 kHz; the lossless formats keep the source rate.
    static func targetSampleRate(_ rate: Double, for target: FileFormat) -> Double {
        target == .m4a ? min(rate, 48_000) : rate
    }

    static func fileSettings(for target: FileFormat, sampleRate: Double, channels: AVAudioChannelCount, bitDepth: Int) -> [String: Any] {
        var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        switch target {
        case .m4a:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = channels == 1 ? 128_000 : 256_000
        case .alac:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = bitDepth
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVEncoderBitDepthHintKey] = bitDepth
        case .wav, .aiff, .caf:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = bitDepth
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = target == .aiff
            settings[AVLinearPCMIsNonInterleaved] = false
        default:
            break
        }
        return settings
    }
}
