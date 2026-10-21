import Foundation

// Settings for the photo tools: Edit photo, Redact, Remove background, Add background,
// Watermark and Annotate. They travel inside `ImageEdits`, so every tool keeps the usual image
// pipeline (any output format, animation, byte targets). Positions are unit coordinates (0…1)
// of the upright image, origin top-left, so a box drawn on a small preview fits the full photo.

/// Light and colour changes. `nil` leaves a setting alone. Sliders run -1…1 (0 = unchanged);
/// sharpness and vignette run 0…1.
public struct PhotoAdjustments: Codable, Sendable, Equatable {
    public var exposure: Double?
    public var contrast: Double?
    public var saturation: Double?
    /// Positive is warmer (more orange), negative cooler (more blue).
    public var warmth: Double?
    /// Positive is more magenta, negative more green.
    public var tint: Double?
    /// Negative calms bright areas, positive lifts them.
    public var highlights: Double?
    /// Positive opens up dark areas, negative deepens them.
    public var shadows: Double?
    public var sharpness: Double?
    public var vignette: Double?
    /// Core Image's automatic fixes (exposure, colour, contrast), applied before the sliders.
    public var autoEnhance: Bool?

    public init(exposure: Double? = nil, contrast: Double? = nil, saturation: Double? = nil, warmth: Double? = nil,
                tint: Double? = nil, highlights: Double? = nil, shadows: Double? = nil, sharpness: Double? = nil,
                vignette: Double? = nil, autoEnhance: Bool? = nil) {
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
        self.tint = tint
        self.highlights = highlights
        self.shadows = shadows
        self.sharpness = sharpness
        self.vignette = vignette
        self.autoEnhance = autoEnhance
    }

    /// True when nothing would change.
    public var isNeutral: Bool {
        let values = [exposure, contrast, saturation, warmth, tint, highlights, shadows, sharpness, vignette]
        return values.allSatisfy { ($0 ?? 0) == 0 } && autoEnhance != true
    }
}

/// Areas hidden for good. The cover is burnt into the pixels and every bit of hidden information
/// (location, camera details, embedded thumbnails) is removed, so nothing can be recovered.
public struct Redaction: Codable, Sendable, Equatable {
    public enum Style: String, Codable, Sendable, CaseIterable {
        case blur, pixelate, black

        public var displayName: String {
            switch self {
            case .blur: "Blur"
            case .pixelate: "Pixelate"
            case .black: "Black box"
            }
        }
    }

    public var boxes: [UnitRect]
    public var style: Style

    public init(boxes: [UnitRect], style: Style = .pixelate) {
        self.boxes = boxes
        self.style = style
    }
}

/// Lifts the subject off its background (on-device), leaving transparency.
public struct BackgroundRemoval: Codable, Sendable, Equatable {
    public enum Subjects: String, Codable, Sendable, CaseIterable {
        case all, largest
    }

    public var subjects: Subjects
    /// A white outline and a soft shadow, like a sticker.
    public var sticker: Bool
    /// The format the person picked (PNG, HEIC or WebP); the app turns it into the request's target.
    public var format: FileFormat?

    public init(subjects: Subjects = .all, sticker: Bool = false, format: FileFormat? = nil) {
        self.subjects = subjects
        self.sticker = sticker
        self.format = format
    }
}

/// A backdrop for screenshots and pictures: padding, colour or gradient, rounded corners,
/// a soft shadow and an optional window frame.
public struct Beautify: Codable, Sendable, Equatable {
    public enum Backdrop: String, Codable, Sendable, CaseIterable {
        case tangerine, ocean, meadow, dusk, graphite, snow, transparent

        public var displayName: String {
            switch self {
            case .tangerine: "Tangerine"
            case .ocean: "Ocean"
            case .meadow: "Meadow"
            case .dusk: "Dusk"
            case .graphite: "Graphite"
            case .snow: "Snow"
            case .transparent: "None"
            }
        }

        /// Top-left and bottom-right sRGB colours of the gradient (equal for a plain colour).
        public var colours: (start: RGB, end: RGB)? {
            switch self {
            case .tangerine: (RGB(1.00, 0.62, 0.36), RGB(0.86, 0.27, 0.32))
            case .ocean: (RGB(0.30, 0.72, 0.96), RGB(0.24, 0.32, 0.86))
            case .meadow: (RGB(0.62, 0.90, 0.60), RGB(0.16, 0.62, 0.55))
            case .dusk: (RGB(0.98, 0.70, 0.80), RGB(0.45, 0.33, 0.80))
            case .graphite: (RGB(0.30, 0.31, 0.35), RGB(0.12, 0.12, 0.15))
            case .snow: (RGB(0.96, 0.96, 0.97), RGB(0.96, 0.96, 0.97))
            case .transparent: nil
            }
        }
    }

    /// Space around the picture, as a share of its longer side (0…0.3).
    public var padding: Double
    public var backdrop: Backdrop
    /// Corner radius as a share of the picture's shorter side (0…0.1).
    public var cornerRadius: Double
    public var shadow: Bool
    /// A plain title bar with three window buttons above the picture.
    public var windowFrame: Bool

    public init(padding: Double = 0.08, backdrop: Backdrop = .tangerine, cornerRadius: Double = 0.025,
                shadow: Bool = true, windowFrame: Bool = false) {
        self.padding = padding
        self.backdrop = backdrop
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.windowFrame = windowFrame
    }
}

/// Text or a logo laid over the picture.
public struct Watermark: Codable, Sendable, Equatable {
    /// A 3 × 3 grid of places.
    public enum Position: String, Codable, Sendable, CaseIterable {
        case topLeft, top, topRight, left, centre, right, bottomLeft, bottom, bottomRight

        public var displayName: String {
            switch self {
            case .topLeft: "Top left"
            case .top: "Top"
            case .topRight: "Top right"
            case .left: "Left"
            case .centre: "Centre"
            case .right: "Right"
            case .bottomLeft: "Bottom left"
            case .bottom: "Bottom"
            case .bottomRight: "Bottom right"
            }
        }

        /// 0, 0.5 or 1 across and down.
        public var anchor: (x: Double, y: Double) {
            let index = Self.allCases.firstIndex(of: self)!
            return (Double(index % 3) / 2, Double(index / 3) / 2)
        }
    }

    public var text: String
    /// Use the logo picture (the job's second input) instead of the text.
    public var useLogo: Bool
    public var position: Position
    /// 0…1.
    public var opacity: Double
    /// Width of the mark as a share of the picture's width (0.05…0.9).
    public var size: Double
    /// The logo as PNG. Filled in inside the worker from the second input; the app never sends it.
    public var logoPNG: Data?

    public init(text: String = "", useLogo: Bool = false, position: Position = .bottomRight,
                opacity: Double = 0.6, size: Double = 0.25, logoPNG: Data? = nil) {
        self.text = text
        self.useLogo = useLogo
        self.position = position
        self.opacity = opacity
        self.size = size
        self.logoPNG = logoPNG
    }
}

/// A point in unit coordinates of the picture, origin top-left.
public struct PhotoPoint: Codable, Sendable, Equatable, Hashable {
    public var x, y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// One mark drawn by "Annotate…".
public struct Annotation: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case arrow, rectangle, text, step, highlight
    }

    public enum Colour: String, Codable, Sendable, CaseIterable {
        case red, orange, yellow, green, blue, white, black

        public var rgb: RGB {
            switch self {
            case .red: RGB(0.92, 0.20, 0.20)
            case .orange: RGB(0.96, 0.50, 0.10)
            case .yellow: RGB(1.00, 0.85, 0.10)
            case .green: RGB(0.20, 0.72, 0.30)
            case .blue: RGB(0.16, 0.45, 0.95)
            case .white: RGB(1, 1, 1)
            case .black: RGB(0.05, 0.05, 0.05)
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// Arrows point from `start` to `end`; boxes and highlights span them; text and steps sit at `start`.
    public var start: PhotoPoint
    public var end: PhotoPoint
    public var text: String?
    public var number: Int?
    public var colour: Colour

    public init(id: UUID = UUID(), kind: Kind, start: PhotoPoint, end: PhotoPoint, text: String? = nil,
                number: Int? = nil, colour: Colour = .red) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.text = text
        self.number = number
        self.colour = colour
    }
}

/// An sRGB colour, 0…1 per channel.
public struct RGB: Codable, Sendable, Equatable {
    public var red, green, blue: Double
    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

extension UnitRect {
    /// The rectangle limited to the picture (0…1 on both axes).
    public var clampedToUnit: UnitRect {
        let left = min(max(x, 0), 1), top = min(max(y, 0), 1)
        let right = min(max(x + width, 0), 1), bottom = min(max(y + height, 0), 1)
        return UnitRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }

    /// Grown by `share` of its own size on every side, then limited to the picture.
    public func padded(by share: Double) -> UnitRect {
        UnitRect(x: x - width * share, y: y - height * share,
                 width: width * (1 + 2 * share), height: height * (1 + 2 * share)).clampedToUnit
    }
}

extension ImageEdits {
    /// Edits for one or more photo tools, everything else unchanged.
    public static func photo(
        adjustments: PhotoAdjustments? = nil, redaction: Redaction? = nil, removeBackground: BackgroundRemoval? = nil,
        annotations: [Annotation]? = nil, watermark: Watermark? = nil, beautify: Beautify? = nil,
        metadata: MetadataPolicy = .keep
    ) -> ImageEdits {
        var edits = ImageEdits(metadata: metadata)
        edits.adjustments = adjustments
        edits.redaction = redaction
        edits.removeBackground = removeBackground
        edits.annotations = annotations
        edits.watermark = watermark
        edits.beautify = beautify
        return edits
    }
}
