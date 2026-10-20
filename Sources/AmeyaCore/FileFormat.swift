import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A file format Ameya can read or write.
public enum FileFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case jpeg, png, heic, avif, webp, tiff, bmp, gif, pdf

    public var id: String { rawValue }

    public enum Family: String, Codable, Sendable {
        case image, document
    }

    public var family: Family {
        self == .pdf ? .document : .image
    }

    public var displayName: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .webp: "WebP"
        case .tiff: "TIFF"
        case .bmp: "BMP"
        case .gif: "GIF"
        case .pdf: "PDF"
        }
    }

    /// The Uniform Type Identifier ImageIO and the system use for this format.
    public var typeIdentifier: String {
        switch self {
        case .jpeg: "public.jpeg"
        case .png: "public.png"
        case .heic: "public.heic"
        case .avif: "public.avif"
        case .webp: "org.webmproject.webp"
        case .tiff: "public.tiff"
        case .bmp: "com.microsoft.bmp"
        case .gif: "com.compuserve.gif"
        case .pdf: "com.adobe.pdf"
        }
    }

    public var preferredExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .tiff: "tiff"
        default: rawValue
        }
    }

    /// Whether the format can store transparency.
    public var supportsAlpha: Bool {
        switch self {
        case .jpeg, .bmp: false
        default: true
        }
    }

    /// Whether the format can store a timed animation.
    public var supportsAnimation: Bool {
        switch self {
        case .gif, .png, .webp: true
        default: false
        }
    }

    /// Whether the format can store several independent pages.
    public var supportsPages: Bool {
        switch self {
        case .tiff, .pdf: true
        default: false
        }
    }

    public var isLossy: Bool {
        switch self {
        case .jpeg, .heic, .avif, .webp: true
        default: false
        }
    }

    /// Detects a format from the file's contents, falling back to its extension.
    /// Contents win: a PNG named `photo.jpg` is a PNG.
    public static func detect(at url: URL) -> FileFormat? {
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let header = try? handle.read(upToCount: 64), let format = sniff(header) {
                return format
            }
        }
        return fromExtension(url.pathExtension)
    }

    /// Formats this Mac can write: whatever ImageIO can encode, plus PDF (drawn with Core Graphics).
    public static func systemWritable() -> Set<FileFormat> {
        let encodable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        return Set(allCases.filter { $0 == .pdf || encodable.contains($0.typeIdentifier) })
    }

    public static func fromExtension(_ ext: String) -> FileFormat? {
        guard let type = UTType(filenameExtension: ext.lowercased()) else { return nil }
        return allCases.first { candidate in
            guard let candidateType = UTType(candidate.typeIdentifier) else { return false }
            return type.conforms(to: candidateType)
        }
    }

    /// Identifies a format from the first bytes of a file.
    public static func sniff(_ header: Data) -> FileFormat? {
        let bytes = [UInt8](header.prefix(32))
        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset..<offset + prefix.count]) == prefix
        }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts(Array("GIF8".utf8)) { return .gif }
        if starts(Array("%PDF".utf8)) { return .pdf }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if starts(Array("RIFF".utf8)) && starts(Array("WEBP".utf8), at: 8) { return .webp }
        if starts(Array("BM".utf8)) { return .bmp }
        if starts(Array("ftyp".utf8), at: 4), bytes.count >= 12 {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            switch brand {
            case "avif", "avis": return .avif
            case "heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1": return .heic
            default: return nil
            }
        }
        return nil
    }
}
