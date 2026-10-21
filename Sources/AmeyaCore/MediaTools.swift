import Foundation

// Audio and video tools: even volume, fades, trims, speed, channels, joining, audiobooks,
// ringtones, GIFs with a size target, frame extraction, burned-in captions and audio visualisers.
// Each travels inside `ConversionOptions.media`; several inputs arrive in the order shown.

/// How loud "even volume" makes a file, as integrated loudness (EBU R128 / ITU-R BS.1770).
public enum LoudnessTarget: String, Codable, Sendable, Equatable, CaseIterable {
    case podcast, streaming, broadcast

    /// Integrated loudness in LUFS.
    public var lufs: Double {
        switch self {
        case .podcast: -16
        case .streaming: -14
        case .broadcast: -23
        }
    }

    public var title: String {
        switch self {
        case .podcast: "Podcast"
        case .streaming: "Music & streaming"
        case .broadcast: "TV & radio"
        }
    }

    /// The highest true peak allowed, in dBTP.
    public static let truePeakCeiling = -1.0
}

/// Which sound goes to which speaker.
public enum ChannelMix: String, Codable, Sendable, Equatable, CaseIterable {
    /// Both sides mixed into one channel.
    case mono
    /// Left and right swapped.
    case swap
    /// Only the left side, as one channel.
    case leftOnly
    /// Only the right side, as one channel.
    case rightOnly
}

/// What an audio visualiser video shows.
public enum VisualiserStyle: String, Codable, Sendable, Equatable, CaseIterable {
    case bars, wave
}

/// An sRGB colour, 0…1 per component.
public struct VisualiserColor: Codable, Sendable, Equatable {
    public var red, green, blue: Double
    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Still pictures taken from a video at a steady pace.
public enum FrameInterval: Codable, Sendable, Equatable {
    case everySeconds(Double)
    case everyFrames(Int)
}

public enum MediaTool: Codable, Sendable, Equatable {
    /// Integrated loudness to the target, true peak at or under −1 dBTP. A video's picture is copied.
    case evenVolume(LoudnessTarget)
    /// Fades the sound in from silence and out to silence over these many seconds (0 = none).
    case fade(inSeconds: Double, outSeconds: Double)
    /// Keeps the sound from `start` to `end` seconds (`nil` = from the beginning / to the end).
    case trimAudio(start: Double?, end: Double?)
    /// Plays faster or slower (0.5…2) without changing the pitch.
    case speed(Double)
    case channels(ChannelMix)
    /// Several audio files, one after another, into one.
    case joinAudio
    /// Several videos, one after another, into one; other sizes are letterboxed to the first's.
    case joinVideos
    /// Several audio files into one M4B audiobook, one chapter per file named after it.
    /// An image among the inputs becomes the cover. `chapterTitles` are the files' names, in order.
    case audiobook(title: String?, chapterTitles: [String])
    /// A ringtone (M4R) of `seconds` starting at `start`, with a short fade at each end.
    case ringtone(start: Double, seconds: Double)
    /// An animated GIF at or under `targetBytes`, choosing size, frame rate and colours to fit.
    case gif(targetBytes: Int)
    /// A folder of PNG or JPEG pictures, one every `interval`.
    case extractFrames(FrameInterval, format: FileFormat)
    /// A video plus a subtitle file (second input) into an MP4 with the captions drawn in.
    case burnSubtitles
    /// Transcribes the speech (`ConversionOptions.language`), then draws the captions in.
    case autoCaption
    /// An MP4 of the sound with moving bars or a wave over a plain background.
    case visualiser(style: VisualiserStyle, background: VisualiserColor)

    /// Whether the job produces a folder of files.
    public var producesSeveralFiles: Bool {
        if case .extractFrames = self { return true }
        return false
    }

    /// Longest ringtone iPhone accepts.
    public static let maxRingtoneSeconds = 40.0
    public static let speedRange = 0.5...2.0
}
