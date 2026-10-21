import Foundation

/// User-tunable settings for one conversion.
public struct ConversionOptions: Codable, Sendable, Equatable {
    /// 0…1 for lossy formats. `nil` uses the format default.
    public var quality: Double?
    /// Hard cap on decoded pixels per frame, to protect against decompression bombs.
    public var maxPixels: Int
    /// Upper bound on pages/frames read from one file.
    public var maxFrames: Int
    /// Long side, in pixels, for images drawn from vectors (SVG). `nil` keeps the SVG's own size,
    /// or 1024 px when it has none.
    public var rasterLongSide: Int? = nil
    /// Test hooks. Only honoured by DEBUG builds of the worker.
    public var debugDelaySeconds: Double?
    public var debugCrash: Bool?

    public static let defaultMaxPixels = 100_000_000
    public static let defaultMaxFrames = 1_000

    public init(
        quality: Double? = nil,
        maxPixels: Int = ConversionOptions.defaultMaxPixels,
        maxFrames: Int = ConversionOptions.defaultMaxFrames,
        debugDelaySeconds: Double? = nil,
        debugCrash: Bool? = nil
    ) {
        self.quality = quality
        self.maxPixels = maxPixels
        self.maxFrames = maxFrames
        self.debugDelaySeconds = debugDelaySeconds
        self.debugCrash = debugCrash
    }
}

/// What the app asks the worker to do. Sent as JSON on the worker's command line.
public struct ConversionRequest: Codable, Sendable, Equatable {
    /// The source format as detected by the app. The worker can't see file names, and some
    /// formats (DOCX vs ODT, M4A vs MP4) can't be told apart from the first bytes alone.
    public var source: FileFormat?
    public var target: FileFormat
    public var options: ConversionOptions

    public init(source: FileFormat? = nil, target: FileFormat, options: ConversionOptions = ConversionOptions()) {
        self.source = source
        self.target = target
        self.options = options
    }
}

/// Something the user should know about a finished conversion.
public enum ConversionNote: String, Codable, Sendable, Equatable {
    case transparencyFilledWhite
    case onlyFirstFrameKept
    case onlyFirstPageKept
    case animationBecamePages
    case formattingRemoved
    case onlyTextKept
    case onlySoundKept
    case soundRemoved
    case gifShortened
    case lossyAudio
    case subtitleStylingRemoved
    case markdownSimplified
    case madeSquareIcon
    case rawDevelopedWithDefaults
    case unsafeEntriesSkipped
    case specialFilesSkipped
    case externalResourcesSkipped

    public var message: String {
        switch self {
        case .transparencyFilledWhite: "Transparent areas were filled with white."
        case .onlyFirstFrameKept: "Only the first frame of the animation was kept."
        case .onlyFirstPageKept: "Only the first page was kept."
        case .animationBecamePages: "Each animation frame became a separate page."
        case .formattingRemoved: "Formatting such as fonts, colours and images is removed."
        case .onlyTextKept: "Only the text is kept; layout and pictures are not."
        case .onlySoundKept: "Only the sound is kept."
        case .soundRemoved: "Sound is removed, and colours are limited to 256."
        case .gifShortened: "Only the first 30 seconds were turned into a GIF."
        case .lossyAudio: "AAC is compressed, so some audio detail is lost."
        case .subtitleStylingRemoved: "Subtitle positions and styling are removed."
        case .markdownSimplified: "Headings, lists, links, tables, bold and italic are kept; fonts, colours and images are not."
        case .madeSquareIcon: "The image was made square and saved at every standard icon size."
        case .rawDevelopedWithDefaults: "The RAW photo was developed with the camera's default settings."
        case .unsafeEntriesSkipped: "Entries with unsafe paths (absolute, or containing ..) were left out."
        case .specialFilesSkipped: "Links pointing outside the archive and special files were left out."
        case .externalResourcesSkipped: "Links to outside images, fonts or style sheets were left out."
        }
    }
}

/// What the worker reports back after a successful conversion.
public struct ConversionResult: Codable, Sendable, Equatable {
    public var outputBytes: Int
    public var frames: Int
    public var notes: [ConversionNote]

    public init(outputBytes: Int, frames: Int, notes: [ConversionNote]) {
        self.outputBytes = outputBytes
        self.frames = frames
        self.notes = notes
    }
}

/// Which conversions are offered, and what may be lost, before anything runs.
public struct ConversionMatrix: Sendable {
    private let writable: Set<FileFormat>

    /// - Parameter writable: formats the current system can encode. The app passes the
    ///   formats ImageIO reports as writable, so unsupported targets are never offered.
    public init(writable: Set<FileFormat>) {
        self.writable = writable
    }

    /// Targets offered for one source format, in display order. Never includes the source itself.
    public func targets(for source: FileFormat) -> [FileFormat] {
        FileFormat.allCases.filter { $0 != source && writable.contains($0) && Self.canConvert(from: source, to: $0) }
    }

    /// Whether Ameya has an engine for this pair, regardless of what this Mac can encode.
    public static func canConvert(from source: FileFormat, to target: FileFormat) -> Bool {
        guard source != target else { return false }
        switch (source.family, target.family) {
        case (.image, .image): return true
        case (.image, .document): return target == .pdf
        case (.image, .video): return source == .gif
        case (.document, .document):
            return source == .pdf ? target.isTextDocument : (target.isTextDocument || target == .pdf)
        case (.document, .image): return source == .pdf
        case (.audio, .audio), (.video, .video), (.video, .audio), (.subtitle, .subtitle): return true
        case (.video, .image): return target == .gif
        case (.archive, .archive): return target != .rar
        default: return false
        }
    }

    /// Targets every one of the given sources can be converted to.
    public func commonTargets(for sources: [FileFormat]) -> [FileFormat] {
        guard let first = sources.first else { return [] }
        return sources.dropFirst().reduce(targets(for: first)) { common, source in
            let allowed = Set(targets(for: source))
            return common.filter { allowed.contains($0) }
        }
    }

    /// Losses that *may* happen, shown before converting. The worker reports what actually happened.
    public func possibleLosses(from source: FileFormat, to target: FileFormat) -> [ConversionNote] {
        switch (source.family, target.family) {
        case (.document, .document) where source == .pdf:
            return target == .md ? [.onlyTextKept, .markdownSimplified] : [.onlyTextKept]
        case (.document, .document) where target == .txt:
            return [.formattingRemoved]
        case (.document, .document) where target == .md:
            return [.markdownSimplified]
        case (.image, .image) where target.isIcon:
            return [.madeSquareIcon]
        case (.image, _) where source == .raw:
            return [.rawDevelopedWithDefaults]
        case (.video, .audio):
            return target == .m4a ? [.onlySoundKept, .lossyAudio] : [.onlySoundKept]
        case (.video, .image):
            return [.soundRemoved, .gifShortened]
        case (.audio, .audio):
            return target == .m4a && !source.isLossy ? [.lossyAudio] : []
        case (.subtitle, .subtitle):
            return source == .vtt ? [.subtitleStylingRemoved] : []
        case (.image, .video):
            return [.transparencyFilledWhite]
        case (.image, _), (.document, .image):
            break // image rules below
        default:
            return []
        }
        var notes: [ConversionNote] = []
        if source.supportsAlpha && !target.supportsAlpha {
            notes.append(.transparencyFilledWhite)
        }
        if source.supportsAnimation && !target.supportsAnimation {
            notes.append(target.supportsPages ? .animationBecamePages : .onlyFirstFrameKept)
        }
        if source.supportsPages && !target.supportsPages {
            notes.append(.onlyFirstPageKept)
        }
        return notes
    }
}
