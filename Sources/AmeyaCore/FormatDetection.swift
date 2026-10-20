import Foundation

extension FileFormat {
    /// Detects a file's format from its contents, using the extension only to break ties
    /// that the contents can't settle (e.g. DOCX vs ODT, which are both ZIP files).
    public static func detect(at url: URL) -> FileFormat? {
        var header = Data()
        if let handle = try? FileHandle(forReadingFrom: url) {
            header = (try? handle.read(upToCount: 64)) ?? Data()
            try? handle.close()
        }
        return detect(header: header, fileExtension: url.pathExtension)
    }

    public static func detect(header: Data, fileExtension: String) -> FileFormat? {
        let byExtension = fromExtension(fileExtension)
        let bytes = [UInt8](header.prefix(64))

        // Containers whose first bytes don't say what's inside.
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) { // ZIP
            return [.docx, .odt].contains(byExtension) ? byExtension : nil
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
            return sniffed
        }

        // Text formats with no reliable signature: accept the extension if the bytes look like text.
        if let byExtension, [.txt, .srt, .vtt, .html].contains(byExtension), looksLikeText(bytes) {
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
        var bytes = [UInt8](header.prefix(64))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) } // UTF-8 BOM

        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset..<offset + prefix.count]) == prefix
        }
        func starts(_ text: String, at offset: Int = 0) -> Bool { starts(Array(text.utf8), at: offset) }

        // Images
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts("GIF8") { return .gif }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if starts("RIFF") && starts("WEBP", at: 8) { return .webp }
        if starts("BM") && bytes.count >= 14 { return .bmp }

        // Documents
        if starts("%PDF") { return .pdf }
        if starts("{\\rtf") { return .rtf }
        if starts("WEBVTT") { return .vtt }
        let lowered = String(decoding: bytes.prefix(32), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.hasPrefix("<!doctype html") || lowered.hasPrefix("<html") { return .html }

        // Audio
        if starts("ID3") { return .mp3 }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0, bytes[1] & 0x06 != 0 {
            return .mp3 // MPEG audio frame sync with a non-zero layer (ADTS AAC has layer 0)
        }
        if starts("RIFF") && starts("WAVE", at: 8) { return .wav }
        if starts("FORM") && (starts("AIFF", at: 8) || starts("AIFC", at: 8)) { return .aiff }
        if starts("fLaC") { return .flac }
        if starts("caff") { return .caf }

        // ISO base media (HEIF images and MP4-family audio/video)
        if starts("ftyp", at: 4), bytes.count >= 12 {
            switch String(decoding: bytes[8..<12], as: UTF8.self) {
            case "avif", "avis": return .avif
            case "heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1": return .heic
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

    /// True when the bytes contain no NULs and decode as UTF-8 or a common single-byte encoding.
    static func looksLikeText(_ bytes: [UInt8]) -> Bool {
        if bytes.isEmpty { return true }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) { return true } // UTF-16 BOM
        return !bytes.contains(0)
    }
}
