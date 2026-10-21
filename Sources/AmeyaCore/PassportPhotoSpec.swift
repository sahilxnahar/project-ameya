import Foundation

// Passport and visa photo sizes. The app shows the table; the worker only sees the chosen spec,
// so "Custom size" travels the same way as a country preset.

/// What the passport photo tool makes.
public struct PassportPhotoOptions: Codable, Sendable, Equatable {
    public var spec: PassportSpec
    /// Also make a 4×6 in (10×15 cm) print sheet, as JPEG and PDF, next to the digital photo.
    public var printSheet: Bool
    /// Replace the background with the spec's plain colour (on-device person segmentation).
    public var replaceBackground: Bool

    public init(spec: PassportSpec, printSheet: Bool = false, replaceBackground: Bool = true) {
        self.spec = spec
        self.printSheet = printSheet
        self.replaceBackground = replaceBackground
    }
}

/// The plain background colours official rules ask for.
public enum PassportBackground: String, Codable, Sendable, CaseIterable {
    case white
    case offWhite
    case lightGrey

    /// sRGB components, 0…1.
    public var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .white: (1, 1, 1)
        case .offWhite: (0.96, 0.96, 0.94)
        case .lightGrey: (0.88, 0.88, 0.88)
        }
    }

    public var displayName: String {
        switch self {
        case .white: "white"
        case .offWhite: "off-white"
        case .lightGrey: "light grey"
        }
    }
}

/// One country's photo rules. Lengths are millimetres on the printed photo.
public struct PassportSpec: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Short and plain, used in output names: "India passport" → "photo (India passport).jpg".
    public var name: String
    /// Words people may search for: country names, "visa", "OCI"…
    public var keywords: [String]
    /// ISO region codes this preset is the natural default for (the Mac's region picks it first).
    public var regions: [String]
    public var widthMM: Double
    public var heightMM: Double
    /// Chin to crown (top of head).
    public var headHeightMM: ClosedRange<Double>
    /// Eye line measured up from the bottom edge, where the rules give one.
    public var eyeLineFromBottomMM: ClosedRange<Double>?
    public var background: PassportBackground
    /// Pixel size for upload portals. `nil` uses the printed size at 300 dpi.
    public var digitalWidth: Int?
    public var digitalHeight: Int?
    /// File-size limits for upload portals, in bytes.
    public var maxBytes: Int?
    public var minBytes: Int?
    /// True when the numbers come from secondary sources or vary between offices: the panel then
    /// reminds people to check the official rules.
    public var needsCheck: Bool

    public init(
        id: String, name: String, keywords: [String] = [], regions: [String] = [],
        widthMM: Double, heightMM: Double, headHeightMM: ClosedRange<Double>,
        eyeLineFromBottomMM: ClosedRange<Double>? = nil, background: PassportBackground = .white,
        digitalWidth: Int? = nil, digitalHeight: Int? = nil, maxBytes: Int? = nil, minBytes: Int? = nil,
        needsCheck: Bool = false
    ) {
        self.id = id
        self.name = name
        self.keywords = keywords
        self.regions = regions
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.headHeightMM = headHeightMM
        self.eyeLineFromBottomMM = eyeLineFromBottomMM
        self.background = background
        self.digitalWidth = digitalWidth
        self.digitalHeight = digitalHeight
        self.maxBytes = maxBytes
        self.minBytes = minBytes
        self.needsCheck = needsCheck
    }

    /// Pixel size of the digital photo: the portal size, or the printed size at 300 dpi.
    public var digitalPixelSize: (width: Int, height: Int) {
        if let digitalWidth, let digitalHeight { return (digitalWidth, digitalHeight) }
        return printPixelSize(dpi: 300)
    }

    public func printPixelSize(dpi: Double) -> (width: Int, height: Int) {
        (PassportGeometry.pixels(mm: widthMM, dpi: dpi), PassportGeometry.pixels(mm: heightMM, dpi: dpi))
    }

    /// "35 × 45 mm", or "2 × 2 in" for the US size.
    public var sizeText: String {
        let inches = (widthMM / 25.4, heightMM / 25.4)
        if abs(inches.0 - inches.0.rounded()) < 0.001 && abs(inches.1 - inches.1.rounded()) < 0.001 {
            return "\(Int(inches.0.rounded())) × \(Int(inches.1.rounded())) in"
        }
        return "\(Self.number(widthMM)) × \(Self.number(heightMM)) mm"
    }

    /// One line for the panel: size, head, background, upload size.
    public var summary: String {
        var parts = [sizeText, "head \(Self.number(headHeightMM.lowerBound))–\(Self.number(headHeightMM.upperBound)) mm",
                     "\(background.displayName) background"]
        let pixels = digitalPixelSize
        var digital = "\(pixels.width) × \(pixels.height) px"
        if let maxBytes { digital += ", up to \(maxBytes / 1000) KB" }
        parts.append(digital)
        return parts.joined(separator: " · ")
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// A user-chosen size. Head height follows the common 70–80 % of the photo height (ICAO).
    public static func custom(widthMM: Double, heightMM: Double, background: PassportBackground = .white) -> PassportSpec {
        PassportSpec(id: customID, name: "passport photo", widthMM: widthMM, heightMM: heightMM,
                     headHeightMM: (heightMM * 0.7)...(heightMM * 0.8), background: background)
    }

    public static let customID = "custom"
}

extension PassportSpec {
    /// The preset table. Sources are noted per entry; entries marked `needsCheck` rest on
    /// secondary sources or differ between offices, and the panel says so.
    public static let presets: [PassportSpec] = [
        // India, Passport Seva: 35 × 45 mm, plain white background, face about 80 % of the photo
        // (head height here follows the ICAO 70–80 % band). Indian online forms commonly want
        // JPEG 10–200 KB. Not an official pixel size; 300 dpi of the print size.
        PassportSpec(id: "in-passport", name: "India passport", keywords: ["India", "Bharat", "Passport Seva"],
                     regions: ["IN"], widthMM: 35, heightMM: 45, headHeightMM: 31...36, background: .white,
                     maxBytes: 200_000, minBytes: 10_000, needsCheck: true),
        // India e-Visa (indianvisaonline.gov.in): square JPEG, 350–1000 px a side, 10 KB–1 MB,
        // plain white or light background; printed visa/OCI photos are 2 × 2 in. Head height
        // follows the US 2 × 2 in rule (1–1⅜ in), which Indian missions abroad accept.
        PassportSpec(id: "in-visa", name: "India visa", keywords: ["India", "e-Visa", "evisa"],
                     widthMM: 50.8, heightMM: 50.8, headHeightMM: 25.4...34.9, background: .white,
                     digitalWidth: 600, digitalHeight: 600, maxBytes: 1_000_000, minBytes: 10_000, needsCheck: true),
        // India OCI card (ociservices.gov.in): square JPEG, 200–1500 px a side, up to 200 KB,
        // white background. 2 × 2 in when printed.
        PassportSpec(id: "in-oci", name: "India OCI", keywords: ["India", "OCI", "Overseas Citizen"],
                     widthMM: 50.8, heightMM: 50.8, headHeightMM: 25.4...34.9, background: .white,
                     digitalWidth: 600, digitalHeight: 600, maxBytes: 200_000, minBytes: 10_000, needsCheck: true),
        // USA, travel.state.gov: 2 × 2 in, head 1–1⅜ in chin to top of hair, eyes 1⅛–1⅜ in from
        // the bottom, white or off-white. Digital: square, 600–1200 px; the DS-160 visa form
        // accepts up to 240 KB.
        PassportSpec(id: "us", name: "USA passport", keywords: ["United States", "America", "US", "USA", "visa", "DS-160"],
                     regions: ["US"], widthMM: 50.8, heightMM: 50.8, headHeightMM: 25.4...34.925,
                     eyeLineFromBottomMM: 28.575...34.925, background: .white,
                     digitalWidth: 600, digitalHeight: 600, maxBytes: 240_000),
        // UK, gov.uk: 35 × 45 mm, head 29–34 mm chin to crown, plain cream or light grey.
        // Digital: at least 600 × 750 px, 50 KB–10 MB.
        PassportSpec(id: "uk", name: "UK passport", keywords: ["United Kingdom", "Britain", "GB", "England", "visa"],
                     regions: ["GB"], widthMM: 35, heightMM: 45, headHeightMM: 29...34, background: .lightGrey,
                     digitalWidth: 600, digitalHeight: 750, maxBytes: 10_000_000, minBytes: 50_000),
        // Schengen visa and EU passports (ICAO 9303): 35 × 45 mm, head 32–36 mm. Background:
        // plain and light; several countries prefer light grey, a few accept white only.
        PassportSpec(id: "schengen", name: "Schengen visa", keywords: ["EU", "Europe", "Germany", "France", "Italy",
                                                                       "Spain", "Netherlands", "passport"],
                     regions: ["DE", "FR", "IT", "ES", "NL", "BE", "AT", "PT", "IE", "SE", "DK", "FI", "PL", "GR"],
                     widthMM: 35, heightMM: 45, headHeightMM: 32...36, background: .lightGrey, needsCheck: true),
        // Canada passport (canada.ca): 50 × 70 mm, head 31–36 mm chin to crown, plain white or
        // light-coloured background.
        PassportSpec(id: "ca-passport", name: "Canada passport", keywords: ["Canada"], regions: ["CA"],
                     widthMM: 50, heightMM: 70, headHeightMM: 31...36, background: .white),
        // Canada visa / PR (IRCC): 35 × 45 mm, head 31–36 mm; digital at least 420 × 540 px.
        PassportSpec(id: "ca-visa", name: "Canada visa", keywords: ["Canada", "IRCC", "PR", "permanent resident"],
                     widthMM: 35, heightMM: 45, headHeightMM: 31...36, background: .white,
                     digitalWidth: 420, digitalHeight: 540, needsCheck: true),
        // Australia (passports.gov.au): 35 × 45 mm, head 32–36 mm, plain white or light grey.
        PassportSpec(id: "au", name: "Australia passport", keywords: ["Australia"], regions: ["AU"],
                     widthMM: 35, heightMM: 45, headHeightMM: 32...36, background: .white),
        // China visa (visaforchina / COVA): 33 × 48 mm, head 28–33 mm, white background;
        // digital 354–420 px wide, 472–560 px tall, JPEG 40–120 KB.
        PassportSpec(id: "cn-visa", name: "China visa", keywords: ["China", "PRC", "COVA"], regions: ["CN"],
                     widthMM: 33, heightMM: 48, headHeightMM: 28...33, background: .white,
                     digitalWidth: 354, digitalHeight: 472, maxBytes: 120_000, minBytes: 40_000),
        // Japan passport and visa (MOFA): 35 × 45 mm, face 34 ± 2 mm, 4 ± 2 mm above the head,
        // plain background (white or light).
        PassportSpec(id: "jp", name: "Japan passport", keywords: ["Japan", "Nippon", "visa"], regions: ["JP"],
                     widthMM: 35, heightMM: 45, headHeightMM: 32...36, background: .white),
        // UAE visa / Emirates ID (ICP): 43 × 55 mm, white background, face 70–80 % of the height.
        // Sources disagree on the size (some list 40 × 60 mm); check before printing.
        PassportSpec(id: "ae", name: "UAE visa", keywords: ["United Arab Emirates", "Dubai", "Abu Dhabi", "Emirates ID"],
                     regions: ["AE"], widthMM: 43, heightMM: 55, headHeightMM: 38.5...44, background: .white,
                     needsCheck: true),
        // Singapore (ICA): 35 × 45 mm, head 25–35 mm chin to crown, white background;
        // digital 400 × 514 px.
        PassportSpec(id: "sg", name: "Singapore passport", keywords: ["Singapore", "ICA"], regions: ["SG"],
                     widthMM: 35, heightMM: 45, headHeightMM: 25...35, background: .white,
                     digitalWidth: 400, digitalHeight: 514),
    ]

    /// Presets matching a search, in table order. Empty text matches everything.
    public static func search(_ text: String, in presets: [PassportSpec] = presets) -> [PassportSpec] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return presets }
        return presets.filter { spec in
            ([spec.name] + spec.keywords).contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// The natural first choice for a region code such as "IN", or nil.
    public static func preset(forRegion region: String?) -> PassportSpec? {
        guard let region else { return nil }
        return presets.first { $0.regions.contains(region.uppercased()) }
    }
}
