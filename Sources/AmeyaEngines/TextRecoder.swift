import AmeyaCore
import Foundation

/// Detects the encoding of a text file and rewrites it as UTF-8 without a BOM.
///
/// Detection order: byte-order mark, valid UTF-8, UTF-16 without a BOM (NULs in every other
/// byte), then the system detector restricted to common legacy encodings. Cyrillic single-byte
/// encodings decode almost any byte sequence, so among those the one that yields mostly
/// lower-case letters (as real prose does) wins.
enum TextRecoder {
    struct Decoded: Equatable {
        var text: String
        /// IANA name, e.g. "windows-1252".
        var encodingName: String
        var hadBOM: Bool
    }

    static func cf(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }

    /// Legacy encodings tried when the bytes are neither UTF-8 nor UTF-16, most likely first.
    static let candidates: [String.Encoding] = [
        .windowsCP1252, .shiftJIS, .japaneseEUC, cf(.GB_18030_2000), cf(.big5), cf(.EUC_KR),
        cf(.KOI8_R), .windowsCP1251, cf(.isoLatinCyrillic), .isoLatin2, .windowsCP1250,
        cf(.isoLatinGreek), .windowsCP1253, cf(.isoLatin5), .windowsCP1254, cf(.isoLatin9),
        cf(.isoLatinHebrew), cf(.isoLatinArabic), cf(.isoLatinThai), .isoLatin1,
    ]

    static let cyrillic: [String.Encoding] = [cf(.KOI8_R), .windowsCP1251, cf(.isoLatinCyrillic)]

    static func name(of encoding: String.Encoding) -> String {
        let cfEncoding = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
        return (CFStringConvertEncodingToIANACharSetName(cfEncoding) as String?) ?? "unknown"
    }

    static func encoding(named name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    /// Decodes `data`, detecting its encoding unless `forcedEncoding` (an IANA name) is given.
    static func decode(_ data: Data, forcedEncoding: String? = nil) throws -> Decoded {
        if let forcedEncoding {
            guard let encoding = encoding(named: forcedEncoding) else {
                throw ConversionError.mediaFailed("unknown text encoding \"\(forcedEncoding)\"")
            }
            let (body, bom) = stripBOM(data)
            guard let text = String(data: body, encoding: encoding) else {
                throw ConversionError.mediaFailed("the text isn't valid \(forcedEncoding)")
            }
            return Decoded(text: text, encodingName: name(of: encoding), hadBOM: bom != nil)
        }

        let bytes = [UInt8](data)
        // Byte-order marks. UTF-32 LE must be checked before UTF-16 LE (same first two bytes).
        let boms: [([UInt8], String.Encoding)] = [
            ([0xEF, 0xBB, 0xBF], .utf8), ([0xFF, 0xFE, 0, 0], .utf32LittleEndian), ([0, 0, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian), ([0xFE, 0xFF], .utf16BigEndian),
        ]
        for (bom, encoding) in boms where bytes.starts(with: bom) {
            if let text = String(data: data.dropFirst(bom.count), encoding: encoding) {
                return Decoded(text: text, encodingName: name(of: encoding), hadBOM: true)
            }
        }
        if let text = String(validatingUTF8Data: data) {
            return Decoded(text: text, encodingName: "utf-8", hadBOM: false)
        }
        if let encoding = utf16WithoutBOM(bytes), let text = String(data: data, encoding: encoding) {
            return Decoded(text: text, encodingName: name(of: encoding), hadBOM: false)
        }

        var converted: NSString?
        let detected = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: candidates.map(\.rawValue),
                .useOnlySuggestedEncodingsKey: true,
                .allowLossyKey: false,
            ],
            convertedString: &converted, usedLossyConversion: nil
        )
        var encoding = String.Encoding(rawValue: detected)
        var text = converted as String?
        let latin: [String.Encoding] = [.windowsCP1252, .isoLatin1, .isoLatin2, .windowsCP1250, cf(.isoLatin9), cf(.isoLatin5), .windowsCP1254]
        if text == nil || cyrillic.contains(encoding) || (latin.contains(encoding) && wordsAreWhollyNonASCII(bytes)) {
            if let best = bestCyrillic(data) { (encoding, text) = (best.0, best.1) }
        }
        if let text {
            return Decoded(text: text, encodingName: name(of: encoding), hadBOM: false)
        }
        // ISO-8859-1 maps every byte, so this never fails.
        return Decoded(text: String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) })),
                       encodingName: "iso-8859-1", hadBOM: false)
    }

    /// Re-encodes as UTF-8 with the requested line endings.
    static func recode(_ data: Data, edits: TextEdits) throws -> (Data, Decoded) {
        let decoded = try decode(data, forcedEncoding: edits.encoding)
        var text = decoded.text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        switch edits.lineEndings {
        case .keep: break
        case .lf: text = normalizedLineEndings(text)
        case .crlf: text = normalizedLineEndings(text).replacingOccurrences(of: "\n", with: "\r\n")
        }
        return (Data(text.utf8), decoded)
    }

    /// CRLF and lone CR become LF.
    static func normalizedLineEndings(_ text: String) -> String {
        // Swift treats "\r\n" as one Character, so work on unicode scalars.
        var scalars = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\r" {
                scalars.append("\n")
                previousWasCR = true
                continue
            }
            if scalar == "\n" && previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = false
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Text in a convenient form for parsers: detected encoding, BOM removed, LF line endings.
    static func text(from data: Data) throws -> String {
        var text = try decode(data).text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return normalizedLineEndings(text)
    }

    private static func stripBOM(_ data: Data) -> (Data, [UInt8]?) {
        for bom in [[0xEF, 0xBB, 0xBF], [0xFF, 0xFE], [0xFE, 0xFF]] as [[UInt8]] where data.starts(with: bom) {
            return (data.dropFirst(bom.count), bom)
        }
        return (data, nil)
    }

    /// UTF-16 without a BOM: an even number of bytes with NULs in only one byte position.
    private static func utf16WithoutBOM(_ bytes: [UInt8]) -> String.Encoding? {
        guard bytes.count >= 2, bytes.count % 2 == 0 else { return nil }
        let pairs = bytes.count / 2
        let evenNULs = stride(from: 0, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
        let oddNULs = stride(from: 1, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
        if oddNULs * 3 >= pairs, evenNULs == 0 { return .utf16LittleEndian }
        if evenNULs * 3 >= pairs, oddNULs == 0 { return .utf16BigEndian }
        return nil
    }

    /// True when most words containing non-ASCII bytes are made only of them, as in Cyrillic
    /// text. Accented Latin text mixes them into ASCII words ("café"), so it returns false.
    private static func wordsAreWhollyNonASCII(_ bytes: [UInt8]) -> Bool {
        var whole = 0, mixed = 0
        var high = 0, low = 0
        func endWord() {
            if high >= 2 && low == 0 { whole += 1 } else if high > 0 { mixed += 1 }
            (high, low) = (0, 0)
        }
        for byte in bytes {
            if byte >= 0x80 { high += 1 } else if (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) { low += 1 } else { endWord() }
        }
        endWord()
        return whole > mixed
    }

    /// Among the Cyrillic single-byte encodings, the one whose letters are mostly lower case.
    private static func bestCyrillic(_ data: Data) -> (String.Encoding, String)? {
        var best: (String.Encoding, String, Int)?
        for encoding in cyrillic {
            guard let text = String(data: data, encoding: encoding) else { continue }
            var score = 0
            for scalar in text.unicodeScalars where (0x0400...0x04FF).contains(scalar.value) {
                switch scalar.value {
                case 0x0430...0x044F: score += 1 // а…я
                case 0x0410...0x042F: score -= 1 // А…Я: prose is mostly lower case
                case 0x0401, 0x0451: break // Ё ё
                default: score -= 3 // letters rare outside Serbian, Macedonian and Ukrainian
                }
            }
            if best == nil || score > best!.2 { best = (encoding, text, score) }
        }
        guard let best, best.2 > 0 else { return nil }
        return (best.0, best.1)
    }
}

extension String {
    /// Strict UTF-8 decoding: nil if any byte sequence is invalid.
    init?(validatingUTF8Data data: Data) {
        var iterator = data.makeIterator()
        var decoder = UTF8()
        var scalars = String.UnicodeScalarView()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: self = String(scalars); return
            case .error: return nil
            }
        }
    }
}
