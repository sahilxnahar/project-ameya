import Foundation

/// User-tunable settings for one conversion.
public struct ConversionOptions: Codable, Sendable, Equatable {
    /// 0…1 for lossy formats. `nil` uses the format default.
    public var quality: Double?
    /// Hard cap on decoded pixels per frame, to protect against decompression bombs.
    public var maxPixels: Int
    /// Upper bound on pages/frames read from one file.
    public var maxFrames: Int
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
    public var target: FileFormat
    public var options: ConversionOptions

    public init(target: FileFormat, options: ConversionOptions = ConversionOptions()) {
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

    public var message: String {
        switch self {
        case .transparencyFilledWhite: "Transparent areas were filled with white."
        case .onlyFirstFrameKept: "Only the first frame of the animation was kept."
        case .onlyFirstPageKept: "Only the first page was kept."
        case .animationBecamePages: "Each animation frame became a separate page."
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
        FileFormat.allCases.filter { $0 != source && writable.contains($0) }
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
