import Foundation
import ImageIO

/// A file format Ameya can read or write.
public enum FileFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    // Images
    case jpeg, png, heic, avif, webp, tiff, bmp, gif
    // Documents
    case pdf, txt, rtf, html, docx, doc, odt
    // Audio. `alac` is Apple Lossless in an .m4a file; it is only ever a target.
    case mp3, m4a, alac, wav, aiff, caf, flac
    // Video
    case mp4, mov, m4v
    // Subtitles
    case srt, vtt

    public var id: String { rawValue }

    public enum Family: String, Codable, Sendable {
        case image, document, audio, video, subtitle

        /// How long one job may run before it is stopped.
        public var timeout: Duration {
            switch self {
            case .image: .seconds(120)
            case .document: .seconds(180)
            case .audio: .seconds(900)
            case .video: .seconds(3600)
            case .subtitle: .seconds(30)
            }
        }
    }

    public var family: Family {
        switch self {
        case .jpeg, .png, .heic, .avif, .webp, .tiff, .bmp, .gif: .image
        case .pdf, .txt, .rtf, .html, .docx, .doc, .odt: .document
        case .mp3, .m4a, .alac, .wav, .aiff, .caf, .flac: .audio
        case .mp4, .mov, .m4v: .video
        case .srt, .vtt: .subtitle
        }
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
        case .txt: "Plain Text"
        case .rtf: "RTF"
        case .html: "HTML"
        case .docx: "Word (DOCX)"
        case .doc: "Word 97 (DOC)"
        case .odt: "OpenDocument"
        case .mp3: "MP3"
        case .m4a: "AAC (M4A)"
        case .alac: "Apple Lossless"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .caf: "CAF"
        case .flac: "FLAC"
        case .mp4: "MP4"
        case .mov: "MOV"
        case .m4v: "M4V"
        case .srt: "SRT"
        case .vtt: "WebVTT"
        }
    }

    /// The Uniform Type Identifier. ImageIO uses it for image formats.
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
        case .txt: "public.plain-text"
        case .rtf: "public.rtf"
        case .html: "public.html"
        case .docx: "org.openxmlformats.wordprocessingml.document"
        case .doc: "com.microsoft.word.doc"
        case .odt: "org.oasis-open.opendocument.text"
        case .mp3: "public.mp3"
        case .m4a, .alac: "com.apple.m4a-audio"
        case .wav: "com.microsoft.waveform-audio"
        case .aiff: "public.aiff-audio"
        case .caf: "com.apple.coreaudio-format"
        case .flac: "org.xiph.flac"
        case .mp4: "public.mpeg-4"
        case .mov: "com.apple.quicktime-movie"
        case .m4v: "com.apple.m4v-video"
        case .srt: "public.srt"
        case .vtt: "org.w3.webvtt"
        }
    }

    /// File name extensions recognised for this format, preferred one first.
    public var extensions: [String] {
        switch self {
        case .jpeg: ["jpg", "jpeg", "jpe", "jfif"]
        case .png: ["png", "apng"]
        case .heic: ["heic", "heif", "hif"]
        case .tiff: ["tiff", "tif"]
        case .bmp: ["bmp", "dib"]
        case .txt: ["txt", "text", "log"]
        case .html: ["html", "htm", "xhtml"]
        case .alac: [] // written as .m4a; never detected as a source
        case .wav: ["wav", "wave"]
        case .aiff: ["aiff", "aif", "aifc"]
        case .mov: ["mov", "qt"]
        default: [rawValue]
        }
    }

    public var preferredExtension: String {
        self == .alac ? "m4a" : extensions[0]
    }

    // MARK: Image capabilities (also used for PDF pages)

    public var supportsAlpha: Bool {
        switch self {
        case .png, .heic, .avif, .webp, .tiff, .gif, .pdf: true
        default: false
        }
    }

    public var supportsAnimation: Bool {
        switch self {
        case .gif, .png, .webp: true
        default: false
        }
    }

    public var supportsPages: Bool {
        switch self {
        case .tiff, .pdf: true
        default: false
        }
    }

    public var isLossy: Bool {
        switch self {
        case .jpeg, .heic, .avif, .webp, .mp3, .m4a: true
        default: false
        }
    }

    /// Text documents that NSAttributedString can read and write.
    public var isTextDocument: Bool {
        switch self {
        case .txt, .rtf, .html, .docx, .doc, .odt: true
        default: false
        }
    }

    /// Formats this Mac can write. Image formats are whatever ImageIO can encode;
    /// the rest are provided by Ameya's own engines.
    public static func systemWritable() -> Set<FileFormat> {
        let encodable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        return Set(allCases.filter { format in
            switch format {
            case .mp3: false // needs the LGPL MP3 encoder (planned)
            case _ where format.family == .image: encodable.contains(format.typeIdentifier)
            default: true
            }
        })
    }
}
