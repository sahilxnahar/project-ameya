import Foundation

// Tools beyond plain format conversion. Each travels inside `ConversionOptions`, so the worker
// protocol stays a single JSON request. A request with edits may keep the source format.

/// What to do with photo metadata (EXIF, GPS, IPTC) in the output.
public enum MetadataPolicy: String, Codable, Sendable, Equatable {
    case keep
    case removeLocation
    case removeAll
}

/// Edits applied to every frame of an image, in this order: crop, rotate/flip, resize.
public struct ImageEdits: Codable, Sendable, Equatable {
    /// Crop rectangle in unit coordinates (0…1) of the upright image, origin top-left.
    public var crop: UnitRect?
    /// Clockwise rotation: 0, 90, 180 or 270.
    public var rotation: Int
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    /// Fit the longest side to this many pixels (never enlarges).
    public var maxPixelSize: Int?
    public var metadata: MetadataPolicy
    /// Aim for an output at or under this many bytes (lossy formats), e.g. a portal's upload limit.
    public var targetBytes: Int?

    public init(
        crop: UnitRect? = nil,
        rotation: Int = 0,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false,
        maxPixelSize: Int? = nil,
        metadata: MetadataPolicy = .keep,
        targetBytes: Int? = nil
    ) {
        self.crop = crop
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.maxPixelSize = maxPixelSize
        self.metadata = metadata
        self.targetBytes = targetBytes
    }

    public var isIdentity: Bool { self == ImageEdits() }
}

public struct UnitRect: Codable, Sendable, Equatable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Edits applied to a video (and its sound).
public struct VideoEdits: Codable, Sendable, Equatable {
    public var trimStart: Double?
    public var trimEnd: Double?
    public var mute: Bool
    /// Fit the longest side to this many pixels (never enlarges).
    public var maxPixelSize: Int?
    /// Aim for an output at or under this many bytes, e.g. 25 MB for email.
    public var targetBytes: Int?

    public init(trimStart: Double? = nil, trimEnd: Double? = nil, mute: Bool = false, maxPixelSize: Int? = nil, targetBytes: Int? = nil) {
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.mute = mute
        self.maxPixelSize = maxPixelSize
        self.targetBytes = targetBytes
    }
}

/// Page-level PDF tools. Page numbers are 1-based, as people count them.
public enum PDFAction: Codable, Sendable, Equatable {
    /// All inputs, in order, into one PDF (images become pages).
    case merge
    /// One PDF per page.
    case splitEveryPage
    /// One PDF per range, e.g. [1...3, 4...10].
    case splitRanges([ClosedRange<Int>])
    case rotate(degrees: Int, pages: [Int]?)
    case deletePages([Int])
    /// The new order, as original page numbers.
    case reorder([Int])
    case compress(quality: Double)
    /// Add a searchable text layer to scanned pages. With an image source and a text target
    /// (TXT, DOCX, MD, RTF, HTML) it copies the picture's text instead. `nil` uses the Mac's languages.
    case ocr(languages: [String]?)
    /// Small numbers at the bottom centre of every page.
    case addPageNumbers(PageNumberStyle)
    /// Diagonal text across every page; opacity 0…1.
    case watermark(text: String, opacity: Double)
    /// Encrypts the PDF so it needs this password to open. Sent to the worker on stdin, never argv.
    case protect(password: String)
    /// Writes an unencrypted copy; needs the current password. Sent to the worker on stdin.
    case removePassword(password: String)

    /// The password this action carries, if any (kept off the worker's command line).
    public var secret: String? {
        switch self {
        case .protect(let password), .removePassword(let password): password
        default: nil
        }
    }

    /// The same action carrying `secret` instead of its password.
    public func replacingSecret(with secret: String) -> PDFAction {
        switch self {
        case .protect: .protect(password: secret)
        case .removePassword: .removePassword(password: secret)
        default: self
        }
    }

    /// Whether the action produces several files.
    public var producesSeveralFiles: Bool {
        switch self {
        case .splitEveryPage, .splitRanges: true
        default: false
        }
    }
}
