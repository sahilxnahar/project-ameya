import Foundation
import ImageIO

/// A file format Ameya can read or write.
public enum FileFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    // Images
    case jpeg, png, heic, avif, webp, tiff, bmp, gif
    case heics, jp2, psd, exr, tga, pbm, ktx, ktx2, astc, ico, icns
    // Images that can only be read: camera RAW, JPEG XL, DICOM, Radiance HDR, SGI
    case raw, jxl, dicom, hdr, sgi
    // Documents
    case pdf, txt, rtf, html, docx, doc, odt, md
    // E-books and comic archives (document family). CBR can only be read.
    case epub, cbz, cbr
    // Audio. `alac` is Apple Lossless in an .m4a file; it is only ever a target.
    case mp3, m4a, alac, wav, aiff, caf, flac
    // Video
    case mp4, mov, m4v
    // Subtitles
    case srt, vtt
    // Archives. RAR can only be read.
    case zip, tar, tgz, tbz2, txz, sevenZip = "7z", rar
    // Data. YAML and XLSX can only be written.
    case csv, tsv, json, plist, xml, yaml, xlsx
    // Contacts and GPS tracks. KMZ can only be read.
    case vcf, gpx, kml, kmz, geojson

    public var id: String { rawValue }

    public enum Family: String, Codable, Sendable {
        case image, document, audio, video, subtitle, archive, data, contacts, geo

        /// How long one job may run before it is stopped.
        public var timeout: Duration {
            switch self {
            case .image: .seconds(120)
            case .document: .seconds(180)
            case .audio: .seconds(900)
            case .video: .seconds(3600)
            case .subtitle: .seconds(30)
            case .archive: .seconds(1800)
            case .data: .seconds(300)
            case .contacts, .geo: .seconds(120)
            }
        }
    }

    public var family: Family {
        switch self {
        case .jpeg, .png, .heic, .avif, .webp, .tiff, .bmp, .gif,
             .heics, .jp2, .psd, .exr, .tga, .pbm, .ktx, .ktx2, .astc, .ico, .icns,
             .raw, .jxl, .dicom, .hdr, .sgi: .image
        case .pdf, .txt, .rtf, .html, .docx, .doc, .odt, .md, .epub, .cbz, .cbr: .document
        case .mp3, .m4a, .alac, .wav, .aiff, .caf, .flac: .audio
        case .mp4, .mov, .m4v: .video
        case .srt, .vtt: .subtitle
        case .zip, .tar, .tgz, .tbz2, .txz, .sevenZip, .rar: .archive
        case .csv, .tsv, .json, .plist, .xml, .yaml, .xlsx: .data
        case .vcf: .contacts
        case .gpx, .kml, .kmz, .geojson: .geo
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
        case .heics: "Animated HEIC"
        case .jp2: "JPEG 2000"
        case .psd: "Photoshop (PSD)"
        case .exr: "OpenEXR"
        case .tga: "TGA"
        case .pbm: "Netpbm (PPM)"
        case .ktx: "KTX texture"
        case .ktx2: "KTX2 texture"
        case .astc: "ASTC texture"
        case .ico: "Windows icon (ICO)"
        case .icns: "Mac icon (ICNS)"
        case .raw: "Camera RAW"
        case .jxl: "JPEG XL"
        case .dicom: "DICOM"
        case .hdr: "Radiance HDR"
        case .sgi: "SGI"
        case .pdf: "PDF"
        case .txt: "Plain Text"
        case .rtf: "RTF"
        case .html: "HTML"
        case .docx: "Word (DOCX)"
        case .doc: "Word 97 (DOC)"
        case .odt: "OpenDocument"
        case .md: "Markdown"
        case .epub: "EPUB"
        case .cbz: "Comic book (CBZ)"
        case .cbr: "Comic book (CBR)"
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
        case .zip: "ZIP"
        case .tar: "TAR"
        case .tgz: "TAR.GZ"
        case .tbz2: "TAR.BZ2"
        case .txz: "TAR.XZ"
        case .sevenZip: "7-Zip"
        case .rar: "RAR"
        case .csv: "CSV"
        case .tsv: "TSV"
        case .json: "JSON"
        case .plist: "Property List"
        case .xml: "XML"
        case .yaml: "YAML"
        case .xlsx: "Excel (XLSX)"
        case .vcf: "vCard"
        case .gpx: "GPX"
        case .kml: "KML"
        case .kmz: "KMZ"
        case .geojson: "GeoJSON"
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
        case .heics: "public.heics"
        case .jp2: "public.jpeg-2000"
        case .psd: "com.adobe.photoshop-image"
        case .exr: "com.ilm.openexr-image"
        case .tga: "com.truevision.tga-image"
        case .pbm: "public.pbm"
        case .ktx: "org.khronos.ktx"
        case .ktx2: "org.khronos.ktx2"
        case .astc: "org.khronos.astc"
        case .ico: "com.microsoft.ico"
        case .icns: "com.apple.icns"
        case .raw: "public.camera-raw-image"
        case .jxl: "public.jpeg-xl"
        case .dicom: "org.nema.dicom"
        case .hdr: "public.radiance"
        case .sgi: "com.sgi.sgi-image"
        case .pdf: "com.adobe.pdf"
        case .txt: "public.plain-text"
        case .rtf: "public.rtf"
        case .html: "public.html"
        case .docx: "org.openxmlformats.wordprocessingml.document"
        case .doc: "com.microsoft.word.doc"
        case .odt: "org.oasis-open.opendocument.text"
        case .md: "net.daringfireball.markdown"
        case .epub: "org.idpf.epub-container"
        case .cbz: "public.cbz-archive"
        case .cbr: "public.cbr-archive"
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
        case .zip: "public.zip-archive"
        case .tar: "public.tar-archive"
        case .tgz: "org.gnu.gnu-zip-tar-archive"
        case .tbz2: "public.tar-bzip2-archive"
        case .txz: "org.tukaani.tar-xz-archive"
        case .sevenZip: "org.7-zip.7-zip-archive"
        case .rar: "com.rarlab.rar-archive"
        case .csv: "public.comma-separated-values-text"
        case .tsv: "public.tab-separated-values-text"
        case .json: "public.json"
        case .plist: "com.apple.property-list"
        case .xml: "public.xml"
        case .yaml: "public.yaml"
        case .xlsx: "org.openxmlformats.spreadsheetml.sheet"
        case .vcf: "public.vcard"
        case .gpx: "com.topografix.gpx"
        case .kml: "com.google.earth.kml"
        case .kmz: "com.google.earth.kmz"
        case .geojson: "public.geojson"
        }
    }

    /// File name extensions recognised for this format, most common first.
    public var extensions: [String] {
        switch self {
        case .jpeg: ["jpg", "jpeg", "jpe", "jfif"]
        case .png: ["png", "apng"]
        case .heic: ["heic", "heif", "hif"]
        case .heics: ["heics", "heifs"]
        case .tiff: ["tiff", "tif"]
        case .bmp: ["bmp", "dib"]
        case .jp2: ["jp2", "j2k", "jpf", "jpx", "jpm"]
        case .tga: ["tga", "icb", "vda", "vst"]
        case .pbm: ["ppm", "pgm", "pbm", "pnm"]
        case .raw: ["dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "rwl",
                    "pef", "srw", "3fr", "fff", "iiq", "mos", "mrw", "x3f", "erf", "kdc", "dcr"]
        case .dicom: ["dcm", "dicom"]
        case .hdr: ["hdr", "rgbe"]
        case .sgi: ["sgi", "rgb", "bw"]
        case .txt: ["txt", "text", "log"]
        case .html: ["html", "htm", "xhtml"]
        case .md: ["md", "markdown", "mdown", "mkd"]
        case .alac: [] // written as .m4a; never detected as a source
        case .wav: ["wav", "wave"]
        case .aiff: ["aiff", "aif", "aifc"]
        case .mov: ["mov", "qt"]
        case .tgz: ["tgz", "gz"]
        case .tbz2: ["tbz2", "tbz", "bz2"]
        case .txz: ["txz", "xz"]
        case .vcf: ["vcf", "vcard"]
        case .tsv: ["tsv", "tab"]
        case .yaml: ["yaml", "yml"]
        default: [rawValue]
        }
    }

    public var preferredExtension: String {
        switch self {
        case .alac: "m4a"
        case .tgz: "tar.gz"
        case .tbz2: "tar.bz2"
        case .txz: "tar.xz"
        default: extensions[0]
        }
    }

    // MARK: Image capabilities (also used for PDF pages)

    public var supportsAlpha: Bool {
        switch self {
        case .png, .heic, .avif, .webp, .tiff, .gif, .pdf, .heics, .jp2, .psd, .exr, .tga,
             .ktx, .ktx2, .astc, .ico, .icns, .jxl, .sgi: true
        default: false
        }
    }

    public var supportsAnimation: Bool {
        switch self {
        case .gif, .png, .webp, .heics: true
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
        case .jpeg, .heic, .heics, .avif, .webp, .jp2, .astc, .mp3, .m4a: true
        default: false
        }
    }

    /// Icon formats: the image is made square and written at several standard sizes.
    public var isIcon: Bool { self == .ico || self == .icns }

    /// Text documents that Ameya can read and write as rich text.
    public var isTextDocument: Bool {
        switch self {
        case .txt, .rtf, .html, .docx, .doc, .odt, .md: true
        default: false
        }
    }

    /// Data formats Ameya can read. YAML and XLSX are written only.
    public var isDataSource: Bool {
        switch self {
        case .csv, .tsv, .json, .plist, .xml: true
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
            case .rar, .cbr: false // proprietary; extraction only
            case .kmz: false // read only
            case _ where format.family == .image: encodable.contains(format.typeIdentifier)
            default: true
            }
        })
    }
}
