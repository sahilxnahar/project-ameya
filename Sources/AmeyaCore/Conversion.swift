import Foundation

/// User-tunable settings for one conversion.
public struct ConversionOptions: Codable, Sendable, Equatable {
    /// 0…1 for lossy formats. `nil` uses the format default.
    public var quality: Double?
    /// Hard cap on decoded pixels per frame, to protect against decompression bombs.
    public var maxPixels: Int
    /// Upper bound on pages/frames read from one file.
    public var maxFrames: Int
    /// Tools (see Operations.swift). With any of these set, the output may keep the source format.
    public var image: ImageEdits?
    public var video: VideoEdits?
    public var pdf: PDFAction?
    /// Test hooks. Only honoured by DEBUG builds of the worker.
    public var debugDelaySeconds: Double?
    public var debugCrash: Bool?

    public var hasEdits: Bool {
        (image.map { !$0.isIdentity } ?? false) || video != nil || pdf != nil
    }

    public static let defaultMaxPixels = 100_000_000
    public static let defaultMaxFrames = 1_000

    public init(
        quality: Double? = nil,
        maxPixels: Int = ConversionOptions.defaultMaxPixels,
        maxFrames: Int = ConversionOptions.defaultMaxFrames,
        image: ImageEdits? = nil,
        video: VideoEdits? = nil,
        pdf: PDFAction? = nil,
        debugDelaySeconds: Double? = nil,
        debugCrash: Bool? = nil
    ) {
        self.quality = quality
        self.maxPixels = maxPixels
        self.maxFrames = maxFrames
        self.image = image
        self.video = video
        self.pdf = pdf
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
    /// Formats of every input when there is more than one (stdin is then a TAR stream, see TarStream).
    public var inputs: [FileFormat]?

    public init(source: FileFormat? = nil, target: FileFormat, options: ConversionOptions = ConversionOptions(), inputs: [FileFormat]? = nil) {
        self.source = source
        self.target = target
        self.options = options
        self.inputs = inputs
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
    case nestedDataFlattened
    case tableValuesTyped
    case xmlStructureMapped
    case xmlNamesAdjusted
    case datesAndDataAsText
    case nullsRemoved
    case cellsTruncated
    // E-books and comics
    case bookLayoutReflowed
    case imagesDropped
    case nonImagesSkipped
    case pagesBecamePictures
    // Tools
    case locationRemoved
    case metadataRemoved
    case resized
    case targetSizeNotReached

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
        case .nestedDataFlattened: "Nested values became columns named like \"a.b\"; lists were written as JSON text in one cell."
        case .tableValuesTyped: "The first row became the keys; numbers and true/false became typed values, empty cells null."
        case .xmlStructureMapped: "Attributes became \"@name\" keys and text \"#text\"; values stay text, comments are dropped."
        case .xmlNamesAdjusted: "Keys that aren't valid XML names were adjusted."
        case .datesAndDataAsText: "Dates and binary data were written as text (ISO 8601 dates, Base64 data)."
        case .nullsRemoved: "Property lists can't store empty (null) values, so those were left out."
        case .cellsTruncated: "Cells longer than Excel's limit of 32,767 characters were shortened."
        case .bookLayoutReflowed: "Page layout and the book's own styling are not kept; the text reflows."
        case .imagesDropped: "Some pictures couldn't be found in the file and were left out."
        case .nonImagesSkipped: "Files in the comic that aren't pictures were left out."
        case .pagesBecamePictures: "Each page became a JPEG picture, so its text can no longer be selected."
        case .locationRemoved: "Location information was removed."
        case .metadataRemoved: "Camera details, location and other hidden information were removed."
        case .resized: "The picture was made smaller."
        case .targetSizeNotReached: "It couldn't be made quite that small; this is the smallest version Ameya could make."
        }
    }
}

/// What the worker reports back after a successful conversion.
public struct ConversionResult: Codable, Sendable, Equatable {
    /// Total bytes written to stdout (for several files, the size of the TAR stream).
    public var outputBytes: Int
    public var frames: Int
    public var notes: [ConversionNote]
    /// Set when the job produced several files: their names, in order. stdout is then a TAR stream.
    public var outputNames: [String]?

    public init(outputBytes: Int, frames: Int, notes: [ConversionNote], outputNames: [String]? = nil) {
        self.outputBytes = outputBytes
        self.frames = frames
        self.notes = notes
        self.outputNames = outputNames
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
        if let route = bookRoute(from: source, to: target) { return route }
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
        case (.data, .data): return source.isDataSource
        case (.data, .document): return source.isDataSource && (target == .html || target == .md)
        default: return false
        }
    }

    private static func dataLosses(from source: FileFormat, to target: FileFormat) -> [ConversionNote] {
        let tables: Set<FileFormat> = [.csv, .tsv, .xlsx, .html, .md]
        var notes: [ConversionNote] = []
        if source == .xml { notes.append(.xmlStructureMapped) }
        if source == .plist { notes.append(.datesAndDataAsText) }
        if tables.contains(source) && !tables.contains(target) { notes.append(.tableValuesTyped) }
        if !tables.contains(source) && tables.contains(target) { notes.append(.nestedDataFlattened) }
        if target == .plist { notes.append(.nullsRemoved) }
        return notes
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
        if let notes = Self.bookLosses(from: source, to: target) { return notes }
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
        case (.data, _):
            return Self.dataLosses(from: source, to: target)
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
