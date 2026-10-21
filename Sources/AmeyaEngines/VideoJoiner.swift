import AmeyaCore
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Several videos, one after another, into one. When every video has the same size, orientation
/// and codec the streams are copied; otherwise everything is re-encoded at the first video's size,
/// with other shapes fitted inside it (black bars) and turned upright.
enum VideoJoiner {
    typealias Job = MediaToolbox.Job

    struct Part {
        var video: AVAssetTrack
        var audio: AVAssetTrack?
        var range: CMTimeRange
        var naturalSize: CGSize
        var transform: CGAffineTransform
        var codec: FourCharCode
        var frameRate: Float

        /// The size as it is shown, after turning.
        var displaySize: CGSize {
            let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
            return CGSize(width: abs(rect.width), height: abs(rect.height))
        }
    }

    static func join(_ files: [URL], job: Job) async throws -> [ConversionNote] {
        guard files.count >= 2 else { throw ConversionError.refused("Add at least two videos to join.") }
        guard let fileType = VideoConverter.fileType(for: job.target) else { throw ConversionError.unsupportedTarget(job.target) }
        var parts: [Part] = []
        for file in files {
            let asset = AVURLAsset(url: file)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw ConversionError.refused("“\(file.lastPathComponent)” has no picture to join.")
            }
            let (size, transform, rate, range, descriptions) = try await video.load(
                .naturalSize, .preferredTransform, .nominalFrameRate, .timeRange, .formatDescriptions)
            let codec = descriptions.first.map(CMFormatDescriptionGetMediaSubType) ?? 0
            parts.append(Part(video: video, audio: try await asset.loadTracks(withMediaType: .audio).first, range: range,
                              naturalSize: size, transform: transform, codec: codec, frameRate: rate))
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ConversionError.mediaFailed("the videos couldn't be prepared")
        }
        var starts: [CMTime] = []
        var cursor = CMTime.zero
        for part in parts {
            starts.append(cursor)
            try videoTrack.insertTimeRange(part.range, of: part.video, at: cursor)
            if let audio = part.audio {
                let audioRange = try await audio.load(.timeRange)
                let duration = CMTimeMinimum(audioRange.duration, part.range.duration)
                try audioTrack.insertTimeRange(CMTimeRange(start: audioRange.start, duration: duration), of: audio, at: cursor)
            }
            cursor = cursor + part.range.duration
        }
        if audioTrack.segments.isEmpty { composition.removeTrack(audioTrack) }

        let first = parts[0]
        let alike = parts.allSatisfy {
            $0.naturalSize == first.naturalSize && $0.transform == first.transform && $0.codec == first.codec
        }
        var notes: [ConversionNote] = [.joinedInOrder]
        if alike {
            videoTrack.preferredTransform = first.transform
            try await MediaToolbox.export(composition, preset: AVAssetExportPresetPassthrough, fileType: fileType,
                                          to: job.output, progress: job.progress)
            return notes
        }

        let render = evenSize(first.displaySize)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        for (part, start) in zip(parts, starts) {
            layer.setTransform(fit(part, in: render), at: start)
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
        instruction.layerInstructions = [layer]
        instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = render
        let fps = min(max(parts.map(\.frameRate).max() ?? 30, 1), 60)
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        videoComposition.instructions = [instruction]
        try await MediaToolbox.export(composition, preset: AVAssetExportPresetHighestQuality, fileType: fileType,
                                      to: job.output, videoComposition: videoComposition, progress: job.progress)

        let shape = first.displaySize.width / max(first.displaySize.height, 1)
        if parts.contains(where: { abs($0.displaySize.width / max($0.displaySize.height, 1) - shape) > 0.01 }) {
            notes.append(.videosLetterboxed)
        }
        return notes
    }

    /// H.264 needs even dimensions.
    static func evenSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(2, (Int(size.width.rounded()) / 2) * 2), height: max(2, (Int(size.height.rounded()) / 2) * 2))
    }

    /// Turns the part upright, scales it to fit inside `render` and centres it.
    static func fit(_ part: Part, in render: CGSize) -> CGAffineTransform {
        let turned = CGRect(origin: .zero, size: part.naturalSize).applying(part.transform)
        let upright = part.transform.concatenating(CGAffineTransform(translationX: -turned.minX, y: -turned.minY))
        let size = part.displaySize
        let scale = min(render.width / max(size.width, 1), render.height / max(size.height, 1))
        let x = (render.width - size.width * scale) / 2
        let y = (render.height - size.height * scale) / 2
        return upright.concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(CGAffineTransform(translationX: x, y: y))
    }
}
