import Foundation
import Testing
@testable import AmeyaCore

/// The shared spec in `spec/` that keeps the Windows app in step with this one: every format,
/// every conversion route with what it may lose, detection test vectors and a TAR stream sample.
/// The Windows tests read these files and must reach the same answers.
///
/// These tests fail when a committed file is out of date. To regenerate them:
///
///     AMEYA_WRITE_SPEC=1 swift test --filter SpecExport
@Suite("Shared spec export")
struct SpecExportTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let specFolder = root.appendingPathComponent("spec", isDirectory: true)
    static var writing: Bool { ProcessInfo.processInfo.environment["AMEYA_WRITE_SPEC"] == "1" }

    @Test func formatsAndRoutes() throws {
        try check("formats.json", Self.formatsJSON())
    }

    @Test func detectionVectors() throws {
        try check("detection-vectors.json", Self.detectionJSON())
    }

    @Test func tarSample() throws {
        try check("tar-sample.tar", Self.tarSample())
    }

    private func check(_ name: String, _ expected: Data) throws {
        let url = Self.specFolder.appendingPathComponent(name)
        if Self.writing {
            try FileManager.default.createDirectory(at: Self.specFolder, withIntermediateDirectories: true)
            try expected.write(to: url)
            return
        }
        let committed = try? Data(contentsOf: url)
        #expect(committed == expected, "spec/\(name) is out of date. Regenerate it with: AMEYA_WRITE_SPEC=1 swift test --filter SpecExport")
    }

    // MARK: formats.json

    struct FormatEntry: Encodable {
        let id: String
        let displayName: String
        let family: String
        let extensions: [String]
        let preferredExtension: String
        let supportsAlpha, supportsAnimation, supportsPages, isLossy, isIcon, isTextDocument: Bool
        let isFFmpegOnly, isFFmpegTarget, isReadOnlyMedia, isDataSource, isCompression, isBookOrComic: Bool
        let isRecognisableImage: Bool
    }

    struct FamilyEntry: Encodable {
        let id: String
        let timeoutSeconds: Int64
    }

    struct NoteEntry: Encodable {
        let id: String
        let message: String
    }

    struct RouteEntry: Encodable {
        let from: String
        let to: String
        /// True when the route exists only while the FFmpeg helper is present.
        let needsFFmpeg: Bool
        let possibleLosses: [String]
    }

    static let families: [FileFormat.Family] = [
        .image, .document, .audio, .video, .subtitle, .archive, .data, .contacts, .geo, .model, .compressed,
    ]

    /// Every case of ConversionNote. A new case must be added here (the count check below fails otherwise).
    static let notes: [ConversionNote] = [
        .transparencyFilledWhite, .onlyFirstFrameKept, .onlyFirstPageKept, .animationBecamePages, .formattingRemoved,
        .onlyTextKept, .onlySoundKept, .soundRemoved, .gifShortened, .lossyAudio, .subtitleStylingRemoved,
        .subtitleEndTimesDropped, .subtitleFrameRateAssumed, .markdownSimplified, .madeSquareIcon,
        .rawDevelopedWithDefaults, .unsafeEntriesSkipped, .specialFilesSkipped, .textRecoded, .madeQRCode,
        .onlyCodesRead, .contactFieldsLimited, .tracksBecamePoints, .trackTimesRemoved, .nestedDataFlattened,
        .tableValuesTyped, .xmlStructureMapped, .xmlNamesAdjusted, .datesAndDataAsText, .nullsRemoved,
        .cellsTruncated, .bookLayoutReflowed, .imagesDropped, .nonImagesSkipped, .pagesBecamePictures,
        .materialsMayNotCarryOver, .separateTexturesNotIncluded, .onlyLargestTableKept, .binaryAsBase64,
        .heldTarArchive, .transcribedOnDevice, .externalResourcesSkipped, .locationRemoved, .metadataRemoved,
        .resized, .targetSizeNotReached, .passportBackgroundReplaced, .passportBackgroundKept,
        .passportEdgesFilled, .passportLowResolution, .passportHeadStraightened, .passportFaceTurned,
        .passportEyesMayBeClosed, .passportCheckRules, .trimmed, .muted, .videoMadeSmaller, .alreadySmallEnough,
        .pdfPagesRecompressed, .scannedPagesMadeSearchable, .textRecognisedFromScans, .textRecognisedInPicture,
        .keepPasswordSafe,
    ]

    @Test func everyNoteIsExported() throws {
        // Decoding each raw value proves the list is complete only together with the source count.
        let source = try String(contentsOf: Self.root.appendingPathComponent("Sources/AmeyaCore/Conversion.swift"), encoding: .utf8)
        let enumBody = source.components(separatedBy: "public enum ConversionNote")[1].components(separatedBy: "public var message")[0]
        let cases = enumBody.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("case ") }
        #expect(cases.count == Self.notes.count, "add the new ConversionNote case to SpecExportTests.notes")
    }

    static func line<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// One object per line, so a diff shows exactly which format or route changed.
    static func list(_ name: String, _ lines: [String], last: Bool = false) -> String {
        "  \"\(name)\": [\n" + lines.map { "    " + $0 }.joined(separator: ",\n") + "\n  ]" + (last ? "\n" : ",\n")
    }

    static func formatsJSON() throws -> Data {
        let matrix = ConversionMatrix(writable: Set(FileFormat.allCases))
        let formats = try FileFormat.allCases.map { format in
            try line(FormatEntry(
                id: format.rawValue, displayName: format.displayName, family: format.family.rawValue,
                extensions: format.extensions, preferredExtension: format.preferredExtension,
                supportsAlpha: format.supportsAlpha, supportsAnimation: format.supportsAnimation,
                supportsPages: format.supportsPages, isLossy: format.isLossy, isIcon: format.isIcon,
                isTextDocument: format.isTextDocument, isFFmpegOnly: format.isFFmpegOnly,
                isFFmpegTarget: format.isFFmpegTarget, isReadOnlyMedia: format.isReadOnlyMedia,
                isDataSource: format.isDataSource, isCompression: format.isCompression,
                isBookOrComic: format.isBookOrComic, isRecognisableImage: format.isRecognisableImage
            ))
        }
        let families = try Self.families.map { family in
            try line(FamilyEntry(id: family.rawValue, timeoutSeconds: family.timeout.components.seconds))
        }
        let notes = try Self.notes.map { try line(NoteEntry(id: $0.rawValue, message: $0.message)) }
        var routes: [String] = []
        for source in FileFormat.allCases {
            for target in FileFormat.allCases where ConversionMatrix.canConvert(from: source, to: target, ffmpeg: true) {
                routes.append(try line(RouteEntry(
                    from: source.rawValue, to: target.rawValue,
                    needsFFmpeg: !ConversionMatrix.canConvert(from: source, to: target, ffmpeg: false),
                    possibleLosses: matrix.possibleLosses(from: source, to: target).map(\.rawValue)
                )))
            }
        }
        let text = "{\n  \"version\": 1,\n" + list("families", families) + list("formats", formats)
            + list("notes", notes) + list("routes", routes, last: true) + "}\n"
        return Data(text.utf8)
    }

    // MARK: detection-vectors.json

    struct Vector: Encodable {
        let name: String
        let hex: String
        let fileName: String
        /// The detected format id, or nil when the file isn't recognised.
        let expected: String?
    }

    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// Inputs for detection: (description, first bytes, file name). The expected answers come from
    /// this app's own detector, so the vectors can never disagree with the Mac.
    static var detectionInputs: [(String, [UInt8], String)] {
        let zip: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 0x14, 0x00]
        let ole: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        let rar: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
        var epub: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 0x0A, 0x00] + [UInt8](repeating: 0, count: 20) + [8, 0, 0, 0]
        epub += bytes("mimetypeapplication/epub+zip")
        var usdz: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 0x0A, 0x00] + [UInt8](repeating: 0, count: 20) + [10, 0, 0, 0]
        usdz += bytes("scene.usdc") + [0, 0, 0, 0]
        var tar = [UInt8](repeating: 0, count: 512)
        tar.replaceSubrange(257..<262, with: bytes("ustar"))
        var dicom = [UInt8](repeating: 0, count: 132)
        dicom.replaceSubrange(128..<132, with: bytes("DICM"))
        var ts = [UInt8](repeating: 0, count: 400)
        ts[0] = 0x47; ts[188] = 0x47; ts[376] = 0x47
        var m2ts = [UInt8](repeating: 0, count: 400)
        m2ts[4] = 0x47; m2ts[196] = 0x47; m2ts[388] = 0x47
        let ftyp: (String, UInt8) -> [UInt8] = { brand, size in [0, 0, 0, size] + bytes("ftyp" + brand) + [0, 0, 0, 0] }
        let gzip: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0, 0x03]
        var gzipNamed: [UInt8] = [0x1F, 0x8B, 0x08, 0x08, 0, 0, 0, 0, 0, 0x03] + bytes("report.pdf") + [0]
        gzipNamed += [0x01, 0x02]
        let utf16Text: [UInt8] = [0xFF, 0xFE] + Array("hello".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        let utf16NoBOM: [UInt8] = Array("a,b\n1,2\n".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        let longComment = "<?xml version=\"1.0\"?>\n<!-- " + String(repeating: "x", count: 600) + " -->\n<svg/>"

        return [
            // Images
            ("JPEG", [0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10] + bytes("JFIF"), "photo.jpg"),
            ("JPEG with a PNG name", [0xFF, 0xD8, 0xFF, 0xE1], "photo.png"),
            ("PNG", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0], "image.png"),
            ("PNG named .jpg", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0], "image.jpg"),
            ("GIF87a", bytes("GIF87a"), "a.gif"),
            ("GIF89a no extension", bytes("GIF89a"), "anim"),
            ("TIFF little-endian", [0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0], "scan.tif"),
            ("TIFF big-endian", [0x4D, 0x4D, 0x00, 0x2A], "scan.tiff"),
            ("TIFF-based RAW", [0x49, 0x49, 0x2A, 0x00], "IMG_1.CR2"),
            ("DNG", [0x49, 0x49, 0x2A, 0x00], "shot.dng"),
            ("Olympus ORF", bytes("IIRO") + [8, 0], "p.orf"),
            ("Panasonic RW2", [0x49, 0x49, 0x55, 0x00], "p.rw2"),
            ("Fujifilm RAF", bytes("FUJIFILMCCD-RAW 0201"), "p.raf"),
            ("WebP", bytes("RIFF") + [0, 0, 0, 0] + bytes("WEBPVP8 "), "x.webp"),
            ("BMP", bytes("BM") + [UInt8](repeating: 0, count: 12), "x.bmp"),
            ("BMP too short", bytes("BM"), "x.bmp"),
            ("PSD", bytes("8BPS") + [0, 1], "x.psd"),
            ("OpenEXR", [0x76, 0x2F, 0x31, 0x01], "x.exr"),
            ("KTX", [0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB], "x.ktx"),
            ("KTX2", [0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB], "x.ktx2"),
            ("ASTC", [0x13, 0xAB, 0xA1, 0x5C], "x.astc"),
            ("ICNS", bytes("icns") + [0, 0, 0, 8], "x.icns"),
            ("ICO", [0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 16, 16], "favicon.ico"),
            ("ICO with zero images", [0x00, 0x00, 0x01, 0x00, 0x00, 0x00], "favicon.ico"),
            ("JPEG 2000 box", [0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A], "x.jp2"),
            ("JPEG 2000 codestream", [0xFF, 0x4F, 0xFF, 0x51], "x.j2k"),
            ("JPEG XL box", [0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20], "x.jxl"),
            ("JPEG XL codestream", [0xFF, 0x0A, 0x00], "x.jxl"),
            ("Radiance HDR", bytes("#?RADIANCE\n"), "x.hdr"),
            ("SGI", [0x01, 0xDA, 0x00, 0x01], "x.sgi"),
            ("DICOM", dicom, "scan.dcm"),
            ("Netpbm P6", bytes("P6\n4 4\n255\n"), "x.ppm"),
            ("Netpbm P7 is not", bytes("P7\n"), "x.pam"),
            ("TGA by extension", [0x00, 0x00, 0x02, 0x00], "x.tga"),
            ("TGA empty", [], "x.tga"),
            ("STL by extension", bytes("solid cube\n"), "cube.stl"),
            ("HEIC", ftyp("heic", 0x18), "IMG.HEIC"),
            ("HEIF mif1", ftyp("mif1", 0x18), "x.heif"),
            ("HEIC sequence", ftyp("hevc", 0x18), "x.heics"),
            ("AVIF", ftyp("avif", 0x1C), "x.avif"),
            ("Canon CR3", ftyp("crx ", 0x18), "x.cr3"),
            ("SVG", bytes("<svg xmlns=\"http://www.w3.org/2000/svg\"/>"), "x.svg"),
            ("SVG after prolog", bytes("<?xml version=\"1.0\"?>\n<!DOCTYPE svg [ <!ENTITY a \"b\"> ]>\n<svg:svg/>"), "x"),
            ("SVG with a long comment", bytes(longComment), "x.svg"),
            ("SVGZ", gzip, "x.svgz"),
            // Documents
            ("PDF", bytes("%PDF-1.7\n"), "doc.pdf"),
            ("RTF", bytes("{\\rtf1\\ansi"), "doc.rtf"),
            ("HTML doctype", bytes("  <!DOCTYPE html><html>"), "page.htm"),
            ("HTML tag", bytes("<html><body>"), "page"),
            ("XHTML", bytes("<?xml version=\"1.0\"?>\n<!DOCTYPE html><html/>"), "page.xhtml"),
            ("DOCX", zip, "letter.docx"),
            ("ODT", zip, "letter.odt"),
            ("ZIP", zip, "files.zip"),
            ("ZIP no extension", zip, "files"),
            ("XLSX is not offered", zip, "sheet.xlsx"),
            ("JAR is not a ZIP to convert", zip, "app.jar"),
            ("KMZ", zip, "map.kmz"),
            ("EPUB by mimetype", epub, "book.zip"),
            ("EPUB by extension", zip, "book.epub"),
            ("CBZ", zip, "comic.cbz"),
            ("CBR that is a ZIP", zip, "comic.CBR"),
            ("CBR", rar, "comic.cbr"),
            ("USDZ by first entry", usdz, "scene.zip"),
            ("USDZ by extension", zip, "scene.usdz"),
            ("DOC", ole, "old.doc"),
            ("XLS is not offered", ole, "old.xls"),
            ("Markdown", bytes("# Title\n\nText\n"), "notes.md"),
            ("Plain text", bytes("hello world\n"), "readme.txt"),
            ("UTF-16 text with BOM", utf16Text, "u16.txt"),
            ("UTF-16 CSV without BOM", utf16NoBOM, "u16.csv"),
            ("Binary named .txt", [0x00, 0x01, 0x02], "bin.txt"),
            ("Unknown text", bytes("hello world"), "notes"),
            ("Empty with no name", [], "empty"),
            ("Empty text file", [], "empty.txt"),
            // Subtitles
            ("SRT", bytes("1\n00:00:01,000 --> 00:00:02,000\nHi\n"), "film.srt"),
            ("SRT named .txt", bytes("1\n00:00:01,000 --> 00:00:02,000\nHi\n"), "film.txt"),
            ("WebVTT", bytes("WEBVTT\n\n"), "x.vtt"),
            ("WebVTT with BOM", [0xEF, 0xBB, 0xBF] + bytes("WEBVTT"), "x"),
            ("ASS by script type", bytes("[Script Info]\nScriptType: v4.00+\n"), "x.txt"),
            ("SSA by script type", [0xEF, 0xBB, 0xBF] + bytes("[Script Info]\r\nScriptType: v4.00\r\n"), "x"),
            ("SSA by extension", bytes("[Script Info]\n; no script type\n"), "x.ssa"),
            ("ASS by default", bytes("[Script Info]\n; no script type\n"), "x"),
            ("TTML", bytes("<?xml version=\"1.0\"?>\n<tt xmlns=\"http://www.w3.org/ns/ttml\">"), "x.xml"),
            ("TTML prefixed", bytes("<tt:tt xmlns:tt=\"http://www.w3.org/ns/ttml\">"), "x"),
            ("DFXP", bytes("<tt xmlns=\"http://www.w3.org/2006/10/ttaf1\">"), "x.dfxp"),
            ("SAMI", bytes("<SAMI>\n<HEAD>"), "x"),
            ("SBV", bytes("0:00:01.000,0:00:02.500\nHi\n"), "x.sbv"),
            ("SBV no extension", bytes("0:00:01.000,0:00:02.500\nHi\n"), "x"),
            ("SBV named .txt", bytes("0:00:01.000,0:00:02.500\nHi\n"), "x.txt"),
            ("MicroDVD", bytes("{1}{1}23.976\n{10}{20}Hi\n"), "x.sub"),
            ("VobSub is not read", [0x00, 0x00, 0x01, 0xBA, 0x44, 0x00], "x.sub"),
            ("LRC", bytes("[ti:Song]\n[00:01.00]Hi\n"), "x.lrc"),
            ("LRC no extension", bytes("[00:01.00]Hi\n"), "x"),
            ("INI is not LRC", bytes("[section]\nkey=value\n"), "x"),
            // Data, contacts and maps
            ("XML plist", bytes("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"x\">\n<plist version=\"1.0\"><dict/></plist>"), "x.xml"),
            ("Binary plist", bytes("bplist00") + [UInt8](repeating: 0, count: 8), "x.plist"),
            ("Old-style plist", bytes("{a = 1;}"), "x.plist"),
            ("XML", bytes("<?xml version=\"1.0\"?><rss/>"), "feed.xml"),
            ("XML without prolog", bytes("<a/>"), "x.xml"),
            ("CSV", bytes("a,b\n1,2\n"), "t.csv"),
            ("TSV", bytes("a\tb\n1\t2\n"), "t.tsv"),
            ("Binary CSV", [0x00, 0x01], "t.csv"),
            ("JSON", bytes("{\"a\": 1}"), "x.json"),
            ("GeoJSON in .json", bytes("{\"type\": \"FeatureCollection\", \"features\": []}"), "x.json"),
            ("GeoJSON", bytes("{\"type\":\"Feature\",\"geometry\":null}"), "x.geojson"),
            ("YAML is write-only", bytes("a: 1\n"), "x.yaml"),
            ("vCard", bytes("BEGIN:VCARD\nVERSION:3.0\n"), "me.vcf"),
            ("GPX", bytes("<?xml version=\"1.0\"?><gpx version=\"1.1\">"), "run.gpx"),
            ("KML", bytes("<kml xmlns=\"http://www.opengis.net/kml/2.2\">"), "x.kml"),
            ("SQLite", bytes("SQLite format 3") + [0], "x.db"),
            ("SQL dump", bytes("CREATE TABLE t (a);\n"), "dump.sql"),
            // Audio
            ("MP3 with ID3", bytes("ID3") + [4, 0], "song.mp3"),
            ("MP3 frame", [0xFF, 0xFB, 0x90, 0x64], "song.mp3"),
            ("ADTS AAC is not MP3", [0xFF, 0xF1, 0x50, 0x80], "song.aac"),
            ("WAV", bytes("RIFF") + [0, 0, 0, 0] + bytes("WAVE"), "x.wav"),
            ("AIFF", bytes("FORM") + [0, 0, 0, 0] + bytes("AIFF"), "x.aiff"),
            ("AIFC", bytes("FORM") + [0, 0, 0, 0] + bytes("AIFC"), "x.aifc"),
            ("FLAC", bytes("fLaC"), "x.flac"),
            ("CAF", bytes("caff"), "x.caf"),
            ("Ogg Vorbis", bytes("OggS") + [UInt8](repeating: 0, count: 24) + bytes("\u{01}vorbis"), "x.ogg"),
            ("Opus", bytes("OggS") + [UInt8](repeating: 0, count: 24) + bytes("OpusHead"), "x.opus"),
            ("M4A", ftyp("M4A ", 0x20), "x.m4a"),
            ("MP4 named .m4a", ftyp("isom", 0x20), "x.m4a"),
            // Video
            ("MP4", ftyp("isom", 0x20), "clip.mp4"),
            ("MP4 named .jpg", ftyp("isom", 0x20), "clip.jpg"),
            ("M4V", ftyp("M4V ", 0x20), "x.m4v"),
            ("MOV brand", ftyp("qt  ", 0x14), "x.mov"),
            ("MOV atom", [0, 0, 0, 8] + bytes("moov"), "x.mov"),
            ("3GP", ftyp("3gp5", 0x18), "x.3gp"),
            ("Unknown ftyp brand", ftyp("xxxx", 0x18), "x.mp4"),
            ("WebM", [0x1A, 0x45, 0xDF, 0xA3] + [UInt8](repeating: 0, count: 20) + bytes("webm"), "x.webm"),
            ("MKV", [0x1A, 0x45, 0xDF, 0xA3] + [UInt8](repeating: 0, count: 20) + bytes("matroska"), "x.mkv"),
            ("AVI", bytes("RIFF") + [0, 0, 0, 0] + bytes("AVI LIST"), "x.avi"),
            ("FLV", bytes("FLV") + [1, 5], "x.flv"),
            ("WMV", [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C], "x.wmv"),
            ("MPEG program stream", [0x00, 0x00, 0x01, 0xBA, 0x44, 0x00], "x.mpg"),
            ("MPEG-TS", ts, "x.ts"),
            ("Blu-ray M2TS", m2ts, "x.m2ts"),
            // Archives and compressed files
            ("7-Zip", [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], "x.7z"),
            ("RAR", rar, "x.rar"),
            ("TAR", tar, "x.tar"),
            ("TAR.GZ", gzip, "photos.tar.gz"),
            ("TGZ", gzip, "photos.tgz"),
            ("Single gzip", gzip, "report.pdf.gz"),
            ("Single gzip with stored name", gzipNamed, "download.gz"),
            ("TAR.BZ2", bytes("BZh9"), "x.tar.bz2"),
            ("Single bzip2", bytes("BZh9"), "x.bz2"),
            ("TAR.XZ", [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], "x.txz"),
            ("Single xz", [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], "x.log.xz"),
            // 3D
            ("USDC", bytes("PXR-USDC"), "x.usdc"),
            ("USDA", bytes("#usda 1.0\n"), "x.usda"),
            ("PLY", bytes("ply\nformat ascii 1.0\n"), "x.ply"),
            ("Alembic", bytes("Ogawa"), "x.abc"),
            ("OBJ", bytes("v 0 0 0\n"), "x.obj"),
        ]
    }

    static func detectionJSON() throws -> Data {
        let vectors = try detectionInputs.map { name, header, fileName in
            let url = URL(fileURLWithPath: "/tmp/\(fileName)")
            let format = FileFormat.refineCompressed(
                FileFormat.detect(header: Data(header), fileExtension: url.pathExtension), url: url
            )
            return try line(Vector(
                name: name, hex: header.map { String(format: "%02x", $0) }.joined(),
                fileName: fileName, expected: format?.rawValue
            ))
        }
        let text = "{\n  \"version\": 1,\n" + list("vectors", vectors, last: true) + "}\n"
        return Data(text.utf8)
    }

    // MARK: tar-sample.tar

    /// Two small files in Ameya's strict TAR dialect. Windows must write identical bytes.
    static func tarSample() throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-spec-\(UUID().uuidString).tar")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        let writer = TarStream.Writer(handle: handle)
        try writer.add(name: "0.png", data: Data("first file\n".utf8))
        try writer.add(name: "page 2 – ü.txt", data: Data(repeating: 0x41, count: 600))
        try writer.finish()
        try handle.close()
        return try Data(contentsOf: url)
    }
}
