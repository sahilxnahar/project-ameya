import AmeyaCore
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Trim, mute, resize and size targets for videos AVFoundation reads (MP4, MOV, M4V, 3GP), written
/// as MP4, MOV or M4V.
///
/// A plain trim or mute keeps the original streams (no quality loss). A new size or a size target
/// re-encodes with the Mac's hardware H.264 encoder at a planned average bitrate (`VideoBudget`),
/// and tries once more, smaller, if the first result is over the target.
enum VideoEditor {
    static func edit(
        input: URL, from source: FileFormat, to target: FileFormat, edits: VideoEdits, output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [ConversionNote] {
        guard let fileType = VideoConverter.fileType(for: target) else { throw ConversionError.unsupportedTarget(target) }
        let asset = AVURLAsset(url: input)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw ConversionError.noVideoTrack }
        let audioTrack = edits.mute ? nil : try await asset.loadTracks(withMediaType: .audio).first
        let assetDuration = try await asset.load(.duration)
        let duration = assetDuration.seconds
        guard duration.isFinite, duration > 0 else { throw ConversionError.unreadable }

        let window = try VideoBudget.window(edits, duration: duration)
        let trimmed = VideoBudget.isTrimmed(window, duration: duration)
        let (naturalSize, transform, nominalRate) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let display = naturalSize.applying(transform)
        let width = Int(abs(display.width).rounded()), height = Int(abs(display.height).rounded())
        let fps = nominalRate > 0 ? Double(nominalRate) : 30
        let resizes = edits.maxPixelSize.map { $0 < max(width, height) } ?? false

        var notes: [ConversionNote] = []
        if trimmed { notes.append(.trimmed) }
        if edits.mute { notes.append(.muted) }

        // Already under the target and nothing else to change: keep it as it is.
        if let targetBytes = edits.targetBytes, !trimmed, !edits.mute, !resizes,
           fileSize(input) <= targetBytes, source == target {
            try FileManager.default.copyItem(at: input, to: output)
            progress(1)
            return [.alreadySmallEnough]
        }

        // The kept part, starting at zero.
        let composition = AVMutableComposition()
        let end = window.end >= duration ? assetDuration : CMTime(seconds: window.end, preferredTimescale: 600)
        let range = CMTimeRange(start: CMTime(seconds: window.start, preferredTimescale: 600), end: end)
        guard let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ConversionError.mediaFailed("the video couldn't be prepared")
        }
        try compositionVideo.insertTimeRange(range, of: videoTrack, at: .zero)
        compositionVideo.preferredTransform = transform
        var compositionAudio: AVMutableCompositionTrack?
        if let audioTrack, let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try track.insertTimeRange(range, of: audioTrack, at: .zero)
            compositionAudio = track
        }

        guard edits.targetBytes != nil || resizes else {
            // Trim and/or mute only: copy the streams.
            if try await export(composition, preset: AVAssetExportPresetPassthrough, fileType: fileType, to: output, progress: progress) {
                return notes
            }
            try? FileManager.default.removeItem(at: output)
            guard try await export(composition, preset: AVAssetExportPresetHighestQuality, fileType: fileType, to: output, progress: progress) else {
                throw ConversionError.mediaFailed("the video couldn't be exported")
            }
            return notes
        }

        let size = (width: width, height: height)
        var plan = try VideoBudget.plan(targetBytes: edits.targetBytes, seconds: window.end - window.start,
                                        hasAudio: compositionAudio != nil, width: width, height: height,
                                        fps: fps, maxPixelSize: edits.maxPixelSize)
        notes.append(.videoMadeSmaller)
        let firstShare = edits.targetBytes == nil ? 1.0 : 0.9
        try await encode(composition, video: compositionVideo, audio: compositionAudio, transform: transform,
                         size: size, plan: plan, fps: fps, fileType: fileType, to: output) { progress($0 * firstShare) }

        if let targetBytes = edits.targetBytes, fileSize(output) > targetBytes {
            plan = VideoBudget.retry(plan, actualBytes: fileSize(output), targetBytes: targetBytes,
                                     width: width, height: height, fps: fps)
            let second = output.deletingLastPathComponent().appendingPathComponent("smaller-\(output.lastPathComponent)")
            try await encode(composition, video: compositionVideo, audio: compositionAudio, transform: transform,
                             size: size, plan: plan, fps: fps, fileType: fileType, to: second) { progress(0.9 + $0 * 0.1) }
            if fileSize(second) < fileSize(output) {
                try FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: second, to: output)
            } else {
                try? FileManager.default.removeItem(at: second)
            }
            if fileSize(output) > targetBytes { notes.append(.targetSizeNotReached) }
        }
        progress(1)
        return notes
    }

    static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    // MARK: Copying streams

    /// Exports with a system preset. Returns false when the preset can't handle these streams.
    private static func export(
        _ asset: AVAsset, preset: String, fileType: AVFileType, to output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Bool {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset),
              session.supportedFileTypes.contains(fileType) else { return false }
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        let box = ExportBox(session)
        let poller = Task {
            while !Task.isCancelled {
                progress(Double(box.session.progress) * 0.99)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { poller.cancel() }
        await box.session.export()
        return box.session.status == .completed
    }

    // MARK: Re-encoding

    /// Reads the composition through a scaling video composition and writes H.264 + AAC at the plan's bitrates.
    private static func encode(
        _ asset: AVMutableComposition, video: AVAssetTrack, audio: AVAssetTrack?, transform: CGAffineTransform,
        size: (width: Int, height: Int), plan: VideoBudget.Plan, fps: Double, fileType: AVFileType, to output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let out = VideoBudget.scaled(width: size.width, height: size.height, longSide: plan.longSide)
        let scale = CGAffineTransform(scaleX: CGFloat(out.width) / CGFloat(max(size.width, 1)),
                                      y: CGFloat(out.height) / CGFloat(max(size.height, 1)))
        let duration = asset.duration

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        layer.setTransform(transform.concatenating(scale), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: out.width, height: out.height)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(max(fps.rounded(), 1), 120)))
        composition.instructions = [instruction]

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ConversionError.mediaFailed("the video couldn't be read") }
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: out.width,
            AVVideoHeightKey: out.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: plan.videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ConversionError.unsupportedTarget(.mp4) }
        writer.add(videoInput)

        var pumps = [MediaPump(output: videoOutput, input: videoInput, writer: writer, label: "video")]
        if let audio, plan.audioBitrate > 0 {
            let audioOutput = AVAssetReaderTrackOutput(track: audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: plan.audioBitrate,
            ])
            audioInput.expectsMediaDataInRealTime = false
            if reader.canAdd(audioOutput), writer.canAdd(audioInput) {
                reader.add(audioOutput)
                writer.add(audioInput)
                pumps.append(MediaPump(output: audioOutput, input: audioInput, writer: writer, label: "audio"))
            }
        }

        guard reader.startReading() else {
            throw ConversionError.mediaFailed(reader.error?.localizedDescription ?? "the video couldn't be read")
        }
        guard writer.startWriting() else {
            throw ConversionError.mediaFailed(writer.error?.localizedDescription ?? "couldn't start writing")
        }
        writer.startSession(atSourceTime: .zero)

        let seconds = max(duration.seconds, 0.01)
        let report: @Sendable (CMTime) -> Void = { time in progress(min(0.99, max(0, time.seconds / seconds))) }
        let silent: @Sendable (CMTime) -> Void = { _ in }
        let jobs = pumps.enumerated().map { index, pump in (pump, index == 0 ? report : silent) }
        await withTaskGroup(of: Void.self) { group in
            for (pump, onTime) in jobs {
                group.addTask { await pump.run(report: onTime) }
            }
        }

        if reader.status == .failed || writer.status == .failed {
            reader.cancelReading()
            writer.cancelWriting()
            let reason = writer.error?.localizedDescription ?? reader.error?.localizedDescription
            throw ConversionError.mediaFailed(reason ?? "the video couldn't be encoded")
        }
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ConversionError.mediaFailed(writer.error?.localizedDescription ?? "the video couldn't be written")
        }
    }
}

/// Moves samples from a reader output to a writer input on its own queue until either runs out.
/// AVFoundation objects aren't Sendable; each pump touches its pair only on its serial queue.
private final class MediaPump: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    let writer: AVAssetWriter
    let queue: DispatchQueue
    private var finished = false

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput, writer: AVAssetWriter, label: String) {
        self.output = output
        self.input = input
        self.writer = writer
        queue = DispatchQueue(label: "org.ameya.video-edit.\(label)")
    }

    func run(report: @escaping @Sendable (CMTime) -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard writer.status == .writing, let sample = output.copyNextSampleBuffer() else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    let time = CMSampleBufferGetPresentationTimeStamp(sample)
                    guard input.append(sample) else {
                        finished = true
                        continuation.resume()
                        return
                    }
                    report(time)
                }
            }
        }
    }
}

/// AVAssetExportSession isn't Sendable; the progress poller only reads `progress`, which is thread-safe.
private final class ExportBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
