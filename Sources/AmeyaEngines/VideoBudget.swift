import AmeyaCore
import Foundation

/// Plans a video edit: the trim window, and for re-encodes the bitrates and frame size.
/// Pure arithmetic shared by the AVFoundation (`VideoEditor`) and FFmpeg paths, so both choose alike.
enum VideoBudget {
    /// Below this the picture turns to mush even at 360p, so a size target needing less is refused.
    static let minimumVideoBitrate = 200_000
    /// MP4/MKV headers and indexes, as a share of the file.
    static let containerOverhead = 0.02
    /// Hardware encoders overshoot their average a little; aim slightly under.
    static let encoderHeadroom = 0.95
    /// Frame sizes tried for a size target, by longest side. 640 is 360p for 16:9.
    static let ladder = [1920, 1280, 960, 640]
    /// Bits per pixel per frame that still looks good with H.264.
    static let acceptableBitsPerPixel = 0.05

    struct Plan: Equatable {
        var videoBitrate: Int
        /// 0 when the output has no sound.
        var audioBitrate: Int
        /// The output's longest side in pixels.
        var longSide: Int
    }

    // MARK: Trim

    /// Start and end, in seconds, of the part of a `duration`-long video to keep.
    static func window(_ edits: VideoEdits, duration: Double) throws -> (start: Double, end: Double) {
        let start = max(0, edits.trimStart ?? 0)
        let end = min(duration, edits.trimEnd.flatMap { $0 > 0 ? $0 : nil } ?? duration)
        guard start < duration else {
            throw ConversionError.cannotFit("The start time is after the end of the video, which is \(clock(duration, adjective: false)) long.")
        }
        guard end - start >= 0.1 else {
            throw ConversionError.cannotFit("The end time needs to be after the start time.")
        }
        return (start, end)
    }

    static func isTrimmed(_ window: (start: Double, end: Double), duration: Double) -> Bool {
        window.start > 0.05 || window.end < duration - 0.05
    }

    // MARK: Bitrate and size

    /// A bitrate that looks good at this size without wasting space: ~0.1 bits per pixel per frame.
    static func qualityBitrate(width: Int, height: Int, fps: Double) -> Int {
        let bits = Double(width * height) * min(max(fps, 1), 60) * 0.1
        return min(40_000_000, max(400_000, Int(bits)))
    }

    /// Scales to fit `longSide` (never enlarges), keeping the aspect ratio, with even dimensions
    /// as H.264 requires.
    static func scaled(width: Int, height: Int, longSide: Int) -> (width: Int, height: Int) {
        let long = max(width, height, 1)
        let factor = long > longSide ? Double(longSide) / Double(long) : 1
        let w = max(2, Int((Double(width) * factor).rounded()) & ~1)
        let h = max(2, Int((Double(height) * factor).rounded()) & ~1)
        return (w, h)
    }

    /// The plan for a re-encode. Without `targetBytes`, good quality at the (possibly reduced) size.
    /// With it, the largest frame the bitrate can carry well; throws `cannotFit` early when even
    /// 360p at the minimum bitrate won't fit, rather than producing mush.
    static func plan(
        targetBytes: Int?, seconds: Double, hasAudio: Bool,
        width: Int, height: Int, fps: Double, maxPixelSize: Int?
    ) throws -> Plan {
        if let maxPixelSize, maxPixelSize < 2 {
            throw ConversionError.invalidData("the size limit must be at least 2 pixels")
        }
        let cap = min(max(width, height), maxPixelSize ?? .max)
        guard let targetBytes else {
            let size = scaled(width: width, height: height, longSide: cap)
            return Plan(videoBitrate: qualityBitrate(width: size.width, height: size.height, fps: fps),
                        audioBitrate: hasAudio ? 160_000 : 0, longSide: cap)
        }
        guard targetBytes > 0 else { throw ConversionError.invalidData("the size target must be above zero") }
        let seconds = max(seconds, 0.1)
        let available = Double(targetBytes) * 8 * (1 - containerOverhead) / seconds
        let audio = !hasAudio ? 0 : available >= 1_000_000 ? 128_000 : available >= 500_000 ? 96_000 : 64_000
        let video = Int((available - Double(audio)) * encoderHeadroom)
        guard video >= minimumVideoBitrate else {
            throw ConversionError.cannotFit(advice(targetBytes: targetBytes, seconds: seconds, hasAudio: hasAudio))
        }
        let long = longSide(for: video, cap: cap, width: width, height: height, fps: fps)
        let size = scaled(width: width, height: height, longSide: long)
        return Plan(videoBitrate: min(video, qualityBitrate(width: size.width, height: size.height, fps: fps)),
                    audioBitrate: audio, longSide: long)
    }

    /// A second, smaller plan after an attempt came out `actualBytes` against a `targetBytes` goal:
    /// at most 85% of the bitrate (less if it was far over) and the next smaller frame, since busy
    /// footage has a size floor that a lower bitrate alone can't get under.
    static func retry(_ plan: Plan, actualBytes: Int, targetBytes: Int, width: Int, height: Int, fps: Double) -> Plan {
        let factor = min(0.85, Double(targetBytes) / Double(max(actualBytes, 1)) * encoderHeadroom)
        let video = max(minimumVideoBitrate, Int(Double(plan.videoBitrate) * factor))
        let smaller = ladder.first { $0 < plan.longSide } ?? plan.longSide
        let long = longSide(for: video, cap: smaller, width: width, height: height, fps: fps)
        return Plan(videoBitrate: video, audioBitrate: plan.audioBitrate, longSide: long)
    }

    /// The largest rung of `ladder` (or `cap`, if smaller) that `bitrate` carries at an acceptable
    /// quality; the smallest rung when none does.
    static func longSide(for bitrate: Int, cap: Int, width: Int, height: Int, fps: Double) -> Int {
        let rungs = [cap] + ladder.filter { $0 < cap }
        for rung in rungs {
            let size = scaled(width: width, height: height, longSide: rung)
            if Double(bitrate) / (Double(size.width * size.height) * max(fps, 1)) >= acceptableBitsPerPixel { return rung }
        }
        return rungs.last ?? cap
    }

    // MARK: Wording

    /// "A 2-hour video can't fit in 8 MB…", with how long a video that size could be.
    static func advice(targetBytes: Int, seconds: Double, hasAudio: Bool) -> String {
        let perSecond = Double(minimumVideoBitrate) / encoderHeadroom + (hasAudio ? 64_000 : 0)
        let longest = Double(targetBytes) * 8 * (1 - containerOverhead) / perSecond
        let size = ByteCountFormatter.string(fromByteCount: Int64(targetBytes), countStyle: .file)
        return "This \(clock(seconds)) video can't fit in \(size) and still be watchable. "
            + "At that size it can be about \(clock(longest, adjective: false)) long, so trim it first or choose a bigger size."
    }

    /// A friendly length: "45-second" / "45 seconds", "4-minute", "1.5-hour" / "1.5 hours".
    static func clock(_ seconds: Double, adjective: Bool = true) -> String {
        let (value, unit): (String, String)
        if seconds < 90 {
            (value, unit) = ("\(max(1, Int(seconds.rounded())))", "second")
        } else if seconds < 90 * 60 {
            (value, unit) = ("\(Int((seconds / 60).rounded()))", "minute")
        } else {
            let hours = (seconds / 360).rounded() / 10
            (value, unit) = (hours == hours.rounded() ? "\(Int(hours))" : "\(hours)", "hour")
        }
        if adjective { return "\(value)-\(unit)" }
        return value == "1" ? "1 \(unit)" : "\(value) \(unit)s"
    }
}
