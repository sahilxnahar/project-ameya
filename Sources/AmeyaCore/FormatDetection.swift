import Foundation

extension FileFormat {
    /// Bytes read from the start of a file for detection. TAR and DICOM signatures sit past byte 128.
    public static let headerLength = 512

    /// ZIP-based formats that are not plain archives; these are never offered ZIP conversions.
    static let zipBasedDocuments: Set<String> = [
        "xlsx", "pptx", "jar", "apk", "ipa", "pages", "numbers", "key", "odp", "ods",
        "sketch", "xpi", "whl", "nupkg", "vsix", "aar", "kmz", "3mf",
    ]

    /// Detects a file's format from its contents, using the extension only to break ties
    /// that the contents can't settle (e.g. DOCX vs ODT, which are both ZIP files).
    public static func detect(at url: URL) -> FileFormat? {
        var header = Data()
        if let handle = try? FileHandle(forReadingFrom: url) {
            header = (try? handle.read(upToCount: headerLength)) ?? Data()
            try? handle.close()
        }
        return refineCompressed(detect(header: header, fileExtension: url.pathExtension), url: url)
    }

    public static func detect(header: Data, fileExtension: String) -> FileFormat? {
        let byExtension = fromExtension(fileExtension)
        let bytes = [UInt8](header.prefix(headerLength))

        // Containers whose first bytes don't say what's inside.
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) || bytes.starts(with: [0x50, 0x4B, 0x05, 0x06]) { // ZIP
            if let byExtension, [.docx, .odt].contains(byExtension) { return byExtension }
            if let book = detectBook(bytes: bytes, fileExtension: fileExtension, isZip: true) { return book }
            if isUSDZ(bytes, fileExtension: fileExtension) { return .usdz }
            return zipBasedDocuments.contains(fileExtension.lowercased()) ? nil : .zip
        }
        if bytes.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) { // OLE compound file
            return byExtension == .doc ? .doc : nil
        }

        if let sniffed = sniff(header) {
            // ISO media files share brands loosely; trust a matching extension within the group.
            let isoMedia: Set<FileFormat> = [.mp4, .mov, .m4v, .m4a]
            if isoMedia.contains(sniffed), let byExtension, isoMedia.contains(byExtension) {
                return byExtension
            }
            // Most camera RAW files are TIFF underneath.
            if sniffed == .tiff, byExtension == .raw { return .raw }
            // A comic book in a RAR (or, rarely, a CBZ that is really a RAR).
            if sniffed == .rar, let comic = detectBook(bytes: bytes, fileExtension: fileExtension, isZip: false) { return comic }
            return sniffed
        }

        // Binary formats with no usable signature.
        if let byExtension, [.tga, .raw, .stl].contains(byExtension), !bytes.isEmpty {
            return byExtension
        }
        // Text formats with no reliable signature: accept the extension if the bytes look like text.
        // YAML and XLSX are left out: Ameya can only write them, so they aren't offered as sources.
        if let byExtension, [.txt, .srt, .vtt, .html, .md, .csv, .tsv, .json, .xml, .plist, .obj, .sql].contains(byExtension),
           looksLikeText(bytes) {
            return byExtension
        }
        return nil
    }

    public static func fromExtension(_ ext: String) -> FileFormat? {
        let ext = ext.lowercased()
        guard !ext.isEmpty else { return nil }
        return allCases.first { $0.extensions.contains(ext) }
    }

    /// Identifies a format from the first bytes of a file. Returns nil when unsure.
    public static func sniff(_ header: Data) -> FileFormat? {
        var bytes = [UInt8](header.prefix(headerLength))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) } // UTF-8 BOM

        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset..<offset + prefix.count]) == prefix
        }
        func starts(_ text: String, at offset: Int = 0) -> Bool { starts(Array(text.utf8), at: offset) }

        // Images
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts("GIF8") { return .gif }
        if starts("IIRO") || starts("IIRS") || starts([0x49, 0x49, 0x55, 0x00]) { return .raw } // Olympus, Panasonic
        if starts("FUJIFILMCCD-RAW") || starts("FOVb") { return .raw } // Fujifilm RAF, Sigma X3F
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if starts("RIFF") && starts("WEBP", at: 8) { return .webp }
        if starts("BM") && bytes.count >= 14 { return .bmp }
        if starts("8BPS") { return .psd }
        if starts([0x76, 0x2F, 0x31, 0x01]) { return .exr }
        if starts([0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB]) { return .ktx }
        if starts([0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB]) { return .ktx2 }
        if starts([0x13, 0xAB, 0xA1, 0x5C]) { return .astc }
        if starts("icns") { return .icns }
        if starts([0x00, 0x00, 0x01, 0x00]) && bytes.count >= 6 && bytes[4] > 0 && bytes[5] == 0 { return .ico }
        if starts([0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20]) || starts([0xFF, 0x4F, 0xFF, 0x51]) { return .jp2 }
        if starts([0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20]) || starts([0xFF, 0x0A]) { return .jxl }
        if starts("#?RADIANCE") || starts("#?RGBE") { return .hdr }
        if starts([0x01, 0xDA]) && bytes.count >= 4 && bytes[2] <= 1 { return .sgi }
        if starts("DICM", at: 128) { return .dicom }
        if bytes.count >= 3, bytes[0] == UInt8(ascii: "P"), (UInt8(ascii: "1")...UInt8(ascii: "6")).contains(bytes[1]),
           [0x20, 0x09, 0x0A, 0x0D].contains(bytes[2]) {
            return .pbm
        }

        // Documents
        if starts("%PDF") { return .pdf }
        if starts("{\\rtf") { return .rtf }
        if starts("WEBVTT") { return .vtt }
        let lowered = String(decoding: bytes.prefix(32), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.hasPrefix("<!doctype html") || lowered.hasPrefix("<html") { return .html }

        // Data
        if starts("bplist00") { return .plist }
        if lowered.hasPrefix("<?xml") || lowered.hasPrefix("<plist") {
            let whole = String(decoding: bytes, as: UTF8.self).lowercased()
            if whole.contains("<!doctype plist") || whole.contains("<plist") { return .plist }
            if whole.contains("<!doctype html") || whole.contains("<html") { return .html } // XHTML
            return .xml
        }

        // Audio
        if starts("ID3") { return .mp3 }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0, bytes[1] & 0x06 != 0 {
            return .mp3 // MPEG audio frame sync with a non-zero layer (ADTS AAC has layer 0)
        }
        if starts("RIFF") && starts("WAVE", at: 8) { return .wav }
        if starts("FORM") && (starts("AIFF", at: 8) || starts("AIFC", at: 8)) { return .aiff }
        if starts("fLaC") { return .flac }
        if starts("caff") { return .caf }

        // Archives
        if starts([0x1F, 0x8B]) { return .tgz }
        if starts("BZh") && bytes.count >= 4 && (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(bytes[3]) { return .tbz2 }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .txz }
        if starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        if starts([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return .rar }
        if starts("ustar", at: 257) { return .tar }

        // Databases and 3D models
        if starts("SQLite format 3\0") { return .sqlite }
        if starts("PXR-USDC") { return .usdc }
        if starts("#usda ") { return .usda }
        if starts("ply"), bytes.count > 3, [0x20, 0x0A, 0x0D].contains(bytes[3]) { return .ply }
        if starts("Ogawa") { return .abc }

        // ISO base media (HEIF images and MP4-family audio/video)
        if starts("ftyp", at: 4), bytes.count >= 12 {
            switch String(decoding: bytes[8..<12], as: UTF8.self) {
            case "avif", "avis": return .avif
            case "heic", "heix", "heim", "heis", "mif1": return .heic
            case "hevc", "hevx", "msf1": return .heics
            case "crx ": return .raw // Canon CR3
            case "M4A ", "M4B ", "M4P ": return .m4a
            case "M4V ", "M4VH", "M4VP": return .m4v
            case "qt  ": return .mov
            case "isom", "iso2", "iso4", "iso5", "iso6", "mp41", "mp42", "avc1", "dash", "MSNV", "3gp4", "3gp5", "3g2a":
                return .mp4
            default: return nil
            }
        }
        if starts("moov", at: 4) || starts("mdat", at: 4) || starts("wide", at: 4) { return .mov }
        return nil
    }

    /// True when the bytes contain no NULs, or start with a UTF-16 byte-order mark.
    static func looksLikeText(_ bytes: [UInt8]) -> Bool {
        if bytes.isEmpty { return true }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) { return true }
        return !bytes.contains(0)
    }
}
