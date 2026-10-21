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
    /// Tools (see Operations.swift). With any of these set, the output may keep the source format.
    public var image: ImageEdits?
    public var video: VideoEdits?
    public var pdf: PDFAction?
    /// Test hooks. Only honoured by DEBUG builds of the worker.
    public var debugDelaySeconds: Double?
    public var debugCrash: Bool?
    /// Spoken language for transcription, as a BCP-47 tag such as "en-GB". `nil` uses the Mac's language.
    public var language: String?
    /// Moves every subtitle earlier (negative) or later (positive) by this many milliseconds.
    public var subtitleShiftMilliseconds: Int?
    /// Frame rate for MicroDVD subtitles. Overrides the file's own `{1}{1}fps` line; default 23.976.
    public var subtitleFrameRate: Double?
    /// Re-encodes a text file in place (same format in and out), e.g. to fix its encoding.
    public var text: TextEdits?
    /// Makes a passport or visa photo (see PassportPhotoSpec.swift). Set after `init`.
    public var passport: PassportPhotoOptions?
    /// Set by `WorkerSecret`: the PDF password follows on stdin, ahead of the file.
    public var secretOnStdin: Bool? = nil

    public var hasEdits: Bool {
        (image.map { !$0.isIdentity } ?? false) || video != nil || pdf != nil || passport != nil
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
        debugCrash: Bool? = nil,
        language: String? = nil,
        subtitleShiftMilliseconds: Int? = nil,
        subtitleFrameRate: Double? = nil,
        text: TextEdits? = nil
    ) {
        self.quality = quality
        self.maxPixels = maxPixels
        self.maxFrames = maxFrames
        self.image = image
        self.video = video
        self.pdf = pdf
        self.debugDelaySeconds = debugDelaySeconds
        self.debugCrash = debugCrash
        self.language = language
        self.subtitleShiftMilliseconds = subtitleShiftMilliseconds
        self.subtitleFrameRate = subtitleFrameRate
        self.text = text
    }
}

/// Edits applied when a text file is converted to itself: the result is always UTF-8 without a BOM.
public struct TextEdits: Codable, Sendable, Equatable {
    public enum LineEndings: String, Codable, Sendable {
        case lf, crlf, keep
    }

    /// IANA name of the source encoding (e.g. "windows-1252"). `nil` detects it.
    public var encoding: String?
    public var lineEndings: LineEndings

    public init(encoding: String? = nil, lineEndings: LineEndings = .lf) {
        self.encoding = encoding
        self.lineEndings = lineEndings
    }

    /// Formats whose text can be re-encoded to UTF-8 in place.
    public static let editableFormats: Set<FileFormat> = [.txt, .srt, .vtt, .md, .csv, .vcf]
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
    case subtitleEndTimesDropped
    case subtitleFrameRateAssumed
    case markdownSimplified
    case madeSquareIcon
    case rawDevelopedWithDefaults
    case unsafeEntriesSkipped
    case specialFilesSkipped
    case textRecoded
    case madeQRCode
    case onlyCodesRead
    case contactFieldsLimited
    case tracksBecamePoints
    case trackTimesRemoved
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
    // 3D models and SQLite
    case materialsMayNotCarryOver
    case separateTexturesNotIncluded
    case onlyLargestTableKept
    case binaryAsBase64
    case heldTarArchive
    case transcribedOnDevice
    case externalResourcesSkipped
    // Tools
    case locationRemoved
    case metadataRemoved
    case resized
    case targetSizeNotReached
    // Passport photos
    case passportBackgroundReplaced
    case passportBackgroundKept
    case passportEdgesFilled
    case passportLowResolution
    case passportHeadStraightened
    case passportFaceTurned
    case passportEyesMayBeClosed
    case passportCheckRules
    // Size presets and video edits
    case trimmed
    case muted
    case videoMadeSmaller
    case alreadySmallEnough
    case pdfPagesRecompressed
    // PDF toolbox and text recognition
    case scannedPagesMadeSearchable
    case textRecognisedFromScans
    case textRecognisedInPicture
    case keepPasswordSafe

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
        case .subtitleEndTimesDropped: "LRC lyrics only keep when each line starts; end times are dropped."
        case .subtitleFrameRateAssumed: "MicroDVD times are counted in video frames; check the frame rate matches your video (23.976 fps unless the file says otherwise)."
        case .markdownSimplified: "Headings, lists, links, tables, bold and italic are kept; fonts, colours and images are not."
        case .madeSquareIcon: "The image was made square and saved at every standard icon size."
        case .rawDevelopedWithDefaults: "The RAW photo was developed with the camera's default settings."
        case .unsafeEntriesSkipped: "Entries with unsafe paths (absolute, or containing ..) were left out."
        case .specialFilesSkipped: "Links pointing outside the archive and special files were left out."
        case .textRecoded: "The text was converted to UTF-8."
        case .madeQRCode: "The text was turned into a QR code."
        case .onlyCodesRead: "Only the QR codes and barcodes in the image are read."
        case .contactFieldsLimited: "Only names, organisation, emails, phones, addresses, birthday and note are kept."
        case .tracksBecamePoints: "Tracks and routes become one row per point."
        case .trackTimesRemoved: "Times are kept only for tracks where every point has one."
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
        case .materialsMayNotCarryOver: "Materials and textures may not carry over."
        case .separateTexturesNotIncluded: "Separate texture and material files (.mtl, images) can't be included."
        case .onlyLargestTableKept: "Only the largest table was kept; convert to JSON or SQL to get every table."
        case .binaryAsBase64: "Binary values (blobs) were written as Base64 text."
        case .heldTarArchive: "It held a TAR archive, so the result is that archive. Add “.tar” to its name if needed, then drop it on Ameya to unpack or convert it."
        case .transcribedOnDevice: "Transcribed on this Mac; check names and technical terms."
        case .externalResourcesSkipped: "Links to outside images, fonts or style sheets were left out."
        case .locationRemoved: "Location information was removed."
        case .metadataRemoved: "Camera details, location and other hidden information were removed."
        case .resized: "The picture was made smaller."
        case .targetSizeNotReached: "It couldn't be made quite that small; this is the smallest version Ameya could make."
        case .passportBackgroundReplaced: "The background was replaced with a plain one. Check the edges around your hair."
        case .passportBackgroundKept: "No outline of a person was found, so the original background was kept."
        case .passportEdgesFilled: "The photo didn't reach every edge, so plain background was added. A photo with more space around you works better."
        case .passportLowResolution: "Your face is small in this photo, so it was enlarged and may look soft. A closer or sharper photo works better."
        case .passportHeadStraightened: "Your head was tilted, so the photo was turned to level your eyes."
        case .passportFaceTurned: "Your face seems turned away. Most countries need you to look straight at the camera."
        case .passportEyesMayBeClosed: "Your eyes may be closed. Most countries need your eyes open."
        case .passportCheckRules: "Rules differ between offices and change over time: check the official requirements before you submit."
        case .trimmed: "The video was trimmed to the chosen start and end."
        case .muted: "The sound was removed."
        case .videoMadeSmaller: "The video was re-encoded to make it smaller, so some detail is lost."
        case .alreadySmallEnough: "It was already small enough, so it was kept as it was."
        case .pdfPagesRecompressed: "Pages that are mostly pictures were saved as smaller JPEG pictures; text pages are unchanged."
        case .scannedPagesMadeSearchable: "Text was recognised on the scanned pages; check names and numbers."
        case .textRecognisedFromScans: "Text was recognised from scanned pages; check names and numbers."
        case .textRecognisedInPicture: "The text was recognised on this Mac; check names and numbers."
        case .keepPasswordSafe: "Keep the password somewhere safe: Ameya can't recover a forgotten one."
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
        canConvert(from: source, to: target, ffmpeg: FFmpegAvailability.isAvailable)
    }

    /// - Parameter ffmpeg: whether the bundled FFmpeg helper is present. Ogg, Opus, MKV, WebM, AVI,
    ///   FLV, WMV, MPEG-TS and MPEG sources, and MP3/Ogg/Opus/MKV/WebM/AVI targets, need it.
    public static func canConvert(from source: FileFormat, to target: FileFormat, ffmpeg: Bool) -> Bool {
        guard source != target, !target.isReadOnlyMedia else { return false }
        if let route = quickWinRoute(from: source, to: target) { return route }
        if let route = bookRoute(from: source, to: target) { return route }
        if source.isFFmpegOnly || target.isFFmpegTarget {
            guard ffmpeg else { return false }
            switch (source.family, target.family) {
            case (.audio, .audio), (.video, .video), (.video, .audio): return true
            default: return false
            }
        }
        if isTranscription(from: source, to: target) { return true }
        switch (source.family, target.family) {
        case (.image, .image): return true
        case (.image, .document):
            // Text: decoded QR codes. Word and Markdown: recognised text (OCR), as in "JPG to Word".
            return target == .pdf || target == .txt || (source.isRecognisableImage && (target == .docx || target == .md))
        case (.image, .video): return source == .gif
        case (.document, .document):
            return source == .pdf ? target.isTextDocument : (target.isTextDocument || target == .pdf)
        case (.document, .image): return source == .pdf || (source == .txt && target == .png) // QR code
        case (.contacts, .data): return target == .csv || target == .json
        case (.data, .contacts): return source == .csv
        case (.geo, .geo): return target != .kmz
        case (.geo, .data): return target == .csv
        case (.audio, .audio), (.video, .video), (.video, .audio), (.subtitle, .subtitle): return true
        case (.video, .image): return target == .gif
        case (.archive, .archive): return target != .rar
        case (.data, .data): return source.isDataSource
        case (.data, .document): return source.isDataSource && (target == .html || target == .md)
        default: return false
        }
    }

    /// Whether a file can be rewritten in its own format with the given edits.
    public static func canEdit(_ format: FileFormat, options: ConversionOptions) -> Bool {
        options.text != nil && TextEdits.editableFormats.contains(format)
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

    /// Speech in an audio or video file becomes a plain transcript or timed captions.
    public static func isTranscription(from source: FileFormat, to target: FileFormat) -> Bool {
        (source.family == .audio || source.family == .video) && [.txt, .srt, .vtt].contains(target)
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
        if let notes = Self.quickWinLosses(from: source, to: target) { return notes }
        if let notes = Self.bookLosses(from: source, to: target) { return notes }
        if Self.isTranscription(from: source, to: target) { return [.transcribedOnDevice] }
        switch (source.family, target.family) {
        case (.document, .image) where source == .txt:
            return [.madeQRCode]
        case (.image, .document) where target == .txt:
            return [.onlyCodesRead]
        case (.image, .document) where target == .docx || target == .md:
            return [.textRecognisedInPicture]
        case (.contacts, _):
            return [.contactFieldsLimited]
        case (.geo, .data):
            return [.tracksBecamePoints]
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
            return FileFormat.subtitleLosses(from: source, to: target)
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
