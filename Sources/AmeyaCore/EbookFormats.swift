import Foundation

// E-books (EPUB) and comic archives (CBZ, CBR). They live in the document family because
// they are read like documents and convert to and from PDF, but their routes are listed
// here explicitly: the generic document rules (anything ↔ text) don't apply to a comic.

extension FileFormat {
    /// EPUB, CBZ and CBR, which have their own conversion rules and engine.
    public var isBookOrComic: Bool {
        switch self {
        case .epub, .cbz, .cbr: true
        default: false
        }
    }

    /// Comic archives: a ZIP (CBZ) or RAR (CBR) of page images.
    public var isComic: Bool { self == .cbz || self == .cbr }

    /// Recognises a ZIP- or RAR-based book. EPUB is identified by its contents: the OCF spec puts
    /// an uncompressed `mimetype` entry first, so "application/epub+zip" sits at byte 38.
    /// Comic archives have no signature of their own and are told apart by extension.
    static func detectBook(bytes: [UInt8], fileExtension: String, isZip: Bool) -> FileFormat? {
        let ext = fileExtension.lowercased()
        if isZip {
            let name = Array("mimetype".utf8), type = Array("application/epub+zip".utf8)
            if bytes.count >= 38 + type.count,
               Array(bytes[30..<38]) == name, Array(bytes[38..<38 + type.count]) == type {
                return .epub
            }
            if ext == "epub" { return .epub } // a sloppily zipped book; the reader copes
        }
        switch ext {
        case "cbz": return .cbz
        case "cbr": return .cbr // many .cbr files are really ZIPs; the reader handles both
        default: return nil
        }
    }
}

extension ConversionMatrix {
    /// Routes involving a book or comic, or nil when neither side is one.
    static func bookRoute(from source: FileFormat, to target: FileFormat) -> Bool? {
        guard source.isBookOrComic || target.isBookOrComic else { return nil }
        switch (source, target) {
        case (.epub, _): return target.isTextDocument || target == .pdf
        case (_, .epub): return source.isTextDocument
        case (.cbz, .pdf), (.cbr, .pdf), (.cbr, .cbz), (.pdf, .cbz): return true
        default: return false
        }
    }

    /// What a book or comic conversion may lose, or nil when neither side is one.
    static func bookLosses(from source: FileFormat, to target: FileFormat) -> [ConversionNote]? {
        guard source.isBookOrComic || target.isBookOrComic else { return nil }
        switch (source, target) {
        case (.epub, .txt): return [.formattingRemoved]
        case (.epub, .md): return [.markdownSimplified]
        case (.epub, _): return [.bookLayoutReflowed]
        case (.pdf, .cbz): return [.pagesBecamePictures]
        case (.txt, .epub), (.md, .epub), (.html, .epub): return []
        case (_, .epub): return [.bookLayoutReflowed]
        default: return []
        }
    }
}
