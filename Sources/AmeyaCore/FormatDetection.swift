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
            if let byExtension, [.docx, .odt, .kmz].contains(byExtension) { return byExtension }
            if let book = detectBook(bytes: bytes, fileExtension: fileExtension, isZip: true) { return book }
            if isUSDZ(bytes, fileExtension: fileExtension) { return .usdz }
            return zipBasedDocuments.contains(fileExtension.lowercased()) ? nil : .zip
        }
        if bytes.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) { // OLE compound file
            return byExtension == .doc ? .doc : nil
        }

        if let sniffed = sniff(header) {
            // ISO media files share brands loosely; trust a matching extension within the group.
            let isoMedia: Set<FileFormat> = [.mp4, .mov, .m4v, .m4a, .threegp]
            if isoMedia.contains(sniffed), let byExtension, isoMedia.contains(byExtension) {
                return byExtension
            }
            // Most camera RAW files are TIFF underneath.
            if sniffed == .tiff, byExtension == .raw { return .raw }
            // A comic book in a RAR (or, rarely, a CBZ that is really a RAR).
            if sniffed == .rar, let comic = detectBook(bytes: bytes, fileExtension: fileExtension, isZip: false) { return comic }
            // Compressed SVG (.svgz) is plain gzip; only the extension says what's inside.
            if sniffed == .tgz, byExtension == .svg { return .svg }
            // A VobSub .sub is MPEG-PS holding only subtitle pictures, not a video Ameya can read.
            if sniffed == .mpg, fileExtension.lowercased() == "sub" { return nil }
            return sniffed
        }
        // An SVG whose root element sits past the header (e.g. after a long comment).
        if byExtension == .svg, looksLikeText(bytes), svgRoot(in: bytes) == .undetermined {
            return .svg
        }

        // Binary formats with no usable signature.
        if let byExtension, [.tga, .raw, .stl].contains(byExtension), !bytes.isEmpty {
            return byExtension
        }
        if let subtitle = sniffSubtitleText(bytes, extension: byExtension) { return subtitle }
        // Text formats with no reliable signature: accept the extension if the bytes look like text.
        // YAML and XLSX are left out: Ameya can only write them, so they aren't offered as sources.
        // MicroDVD is left out: .sub is also VobSub, a binary format Ameya can't read.
        let textFormats: Set<FileFormat> = [.txt, .srt, .vtt, .html, .md, .csv, .tsv, .json, .xml, .plist,
                                            .ass, .ssa, .sbv, .ttml, .lrc, .sami, .vcf, .gpx, .kml, .geojson,
                                            .obj, .sql]
        if let byExtension, textFormats.contains(byExtension), looksLikeText(bytes) {
            if byExtension == .json, looksLikeGeoJSON(bytes) { return .geojson }
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
        if let subtitle = sniffSubtitleSignature(bytes) { return subtitle }

        if case .svg = svgRoot(in: [UInt8](header.prefix(headerLength))) { return .svg }
        if lowered.hasPrefix("begin:vcard") { return .vcf }
        if lowered.hasPrefix("<") {
            let head = String(decoding: bytes, as: UTF8.self)
            if head.contains("<gpx") { return .gpx }
            if head.contains("<kml") { return .kml }
        }

        // Data
        if starts("bplist00") { return .plist }
        if lowered.hasPrefix("<?xml") || lowered.hasPrefix("<plist") {
            let whole = String(decoding: bytes, as: UTF8.self).lowercased()
            if whole.contains("<!doctype plist") || whole.contains("<plist") { return .plist }
            if whole.contains("<!doctype html") || whole.contains("<html") { return .html } // XHTML
            return .xml
        }

        // MPEG-TS: a 0x47 sync byte every 188 bytes; Blu-ray M2TS adds a 4-byte prefix to each packet.
        for (offset, stride) in [(0, 188), (4, 192)] where bytes.count > offset + 2 * stride {
            if bytes[offset] == 0x47 && bytes[offset + stride] == 0x47 && bytes[offset + 2 * stride] == 0x47 {
                return .ts
            }
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
        if starts("OggS") { return starts("OpusHead", at: 28) ? .opus : .ogg }

        // Video containers
        if starts([0x1A, 0x45, 0xDF, 0xA3]) { // Matroska EBML header; the DocType says WebM or Matroska
            let head = Array(bytes.prefix(64)), webm = Array("webm".utf8)
            let isWebM = head.count >= 4 && (0...head.count - 4).contains { Array(head[$0..<$0 + 4]) == webm }
            return isWebM ? .webm : .mkv
        }
        if starts("RIFF") && starts("AVI ", at: 8) { return .avi }
        if starts("FLV") && bytes.count >= 4 && bytes[3] == 1 { return .flv }
        if starts([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C]) {
            return .wmv // ASF header object
        }
        if starts([0x00, 0x00, 0x01, 0xBA]) || starts([0x00, 0x00, 0x01, 0xB3]) { return .mpg } // program stream / MPEG video

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
            case "isom", "iso2", "iso4", "iso5", "iso6", "mp41", "mp42", "avc1", "dash", "MSNV":
                return .mp4
            case let brand where brand.hasPrefix("3gp") || brand.hasPrefix("3g2"):
                return .threegp
            default: return nil
            }
        }
        if starts("moov", at: 4) || starts("mdat", at: 4) || starts("wide", at: 4) { return .mov }
        return nil
    }

    public enum SVGRootScan: Equatable, Sendable {
        /// The first element is `<svg`; `offset` is where it starts in the UTF-8 text.
        case svg(offset: Int)
        /// The first element is something else, or the bytes are not XML text.
        case other
        /// The bytes end before the first element (inside the prolog).
        case undetermined
    }

    /// Finds the root element of XML text, skipping a byte-order mark, the XML declaration,
    /// processing instructions, comments, whitespace and a DOCTYPE (with an internal subset).
    /// UTF-16 text is accepted with a byte-order mark.
    public static func svgRoot(in bytes: [UInt8]) -> SVGRootScan {
        var text = bytes
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            let encoding: String.Encoding = bytes[0] == 0xFF ? .utf16LittleEndian : .utf16BigEndian
            let even = Array(bytes.dropFirst(2).prefix((bytes.count - 2) & ~1))
            guard let string = String(bytes: even, encoding: encoding) else { return .other }
            text = Array(string.utf8)
        } else if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = Array(bytes.dropFirst(3))
        }
        if text.contains(0) { return .other }

        func has(_ prefix: String, at index: Int) -> Bool {
            let prefix = Array(prefix.utf8)
            return text.count >= index + prefix.count && prefix.indices.allSatisfy { text[index + $0] == prefix[$0] }
        }
        func find(_ needle: String, from index: Int) -> Int? {
            let needle = Array(needle.utf8)
            guard text.count >= needle.count else { return nil }
            var position = index
            while position + needle.count <= text.count {
                if needle.indices.allSatisfy({ text[position + $0] == needle[$0] }) { return position }
                position += 1
            }
            return nil
        }

        var index = 0
        while index < text.count {
            let byte = text[index]
            if [0x20, 0x09, 0x0A, 0x0D].contains(byte) { index += 1; continue }
            guard byte == UInt8(ascii: "<") else { return .other }
            if index + 1 >= text.count { return .undetermined }
            if has("<?", at: index) {
                guard let end = find("?>", from: index + 2) else { return .undetermined }
                index = end + 2
            } else if has("<!--", at: index) {
                guard let end = find("-->", from: index + 4) else { return .undetermined }
                index = end + 3
            } else if has("<!", at: index) {
                guard text.count >= index + 9 else { return .undetermined }
                guard String(decoding: text[index..<index + 9], as: UTF8.self).uppercased() == "<!DOCTYPE" else { return .other }
                // Skip to the closing '>', stepping over an internal subset in [...] and quoted strings.
                var position = index + 9
                var inSubset = false
                var quote: UInt8?
                while position < text.count {
                    let character = text[position]
                    if let open = quote {
                        if character == open { quote = nil }
                    } else if character == UInt8(ascii: "\"") || character == UInt8(ascii: "'") {
                        quote = character
                    } else if character == UInt8(ascii: "[") {
                        inSubset = true
                    } else if character == UInt8(ascii: "]") {
                        inSubset = false
                    } else if character == UInt8(ascii: ">"), !inSubset {
                        break
                    }
                    position += 1
                }
                guard position < text.count else { return .undetermined }
                index = position + 1
            } else {
                // The root element. Accept `<svg` and a namespace prefix such as `<svg:svg`.
                var nameEnd = index + 1
                while nameEnd < text.count, ![0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ">"), UInt8(ascii: "/")].contains(text[nameEnd]) {
                    nameEnd += 1
                }
                guard nameEnd < text.count else { return .undetermined }
                let name = String(decoding: text[(index + 1)..<nameEnd], as: UTF8.self)
                let local = name.split(separator: ":").last.map(String.init) ?? name
                return local == "svg" ? .svg(offset: index) : .other
            }
        }
        return .undetermined
    }

    /// True when the bytes contain no NULs, start with a UTF-16 byte-order mark, or look like
    /// UTF-16 without one (NULs only in every other byte, as in mostly-Latin UTF-16 text).
    static func looksLikeText(_ bytes: [UInt8]) -> Bool {
        if bytes.isEmpty { return true }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) { return true }
        guard bytes.contains(0) else { return true }
        let even = stride(from: 0, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
        let odd = stride(from: 1, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
        let pairs = bytes.count / 2
        return pairs >= 2 && (even == 0 || odd == 0) && max(even, odd) * 3 >= pairs
    }

    /// A JSON file whose opening bytes name a GeoJSON object type.
    static func looksLikeGeoJSON(_ bytes: [UInt8]) -> Bool {
        let head = String(decoding: bytes, as: UTF8.self).filter { !$0.isWhitespace }
        return head.contains("\"type\":\"FeatureCollection\"")
            || (head.contains("\"type\":\"Feature\"") && head.contains("\"geometry\""))
    }
}
