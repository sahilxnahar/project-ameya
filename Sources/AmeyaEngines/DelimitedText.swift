import AmeyaCore
import Foundation

/// RFC 4180 CSV and TSV: quoted fields with embedded delimiters, quotes and line breaks;
/// CRLF, LF or CR line endings; a UTF-8 or UTF-16 byte-order mark. Files that aren't
/// valid UTF-8 are read as Windows Latin-1, which is what older Excel versions write.
enum DelimitedText {
    static let maxRows = 1_000_000
    static let maxColumns = 16_384

    static let comma = UInt8(ascii: ","), semicolon = UInt8(ascii: ";"), tab = UInt8(ascii: "\t")
    private static let quote = UInt8(ascii: "\""), cr: UInt8 = 0x0D, lf: UInt8 = 0x0A

    /// Decodes text, honouring a byte-order mark.
    static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xFF, 0xFE]) { return String(data: data, encoding: .utf16LittleEndian).map(dropBOM) ?? "" }
        if bytes.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16BigEndian).map(dropBOM) ?? "" }
        if let text = String(data: data, encoding: .utf8) { return dropBOM(text) }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    private static func dropBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// Parses delimited text into rows of fields. Pass `nil` to detect `,` or `;` (European
    /// Excel uses `;` because `,` is the decimal separator). Blank lines are skipped.
    static func parse(_ text: String, delimiter: UInt8?, maxRows: Int = maxRows) throws -> [[String]] {
        var bytes = Array(text.utf8)
        var delimiter = delimiter
        // Excel's "sep=;" first line names the delimiter explicitly.
        if bytes.count >= 5, bytes.starts(with: Array("sep=".utf8)), bytes.count == 5 || [cr, lf].contains(bytes[5]) {
            delimiter = bytes[4]
            var end = min(bytes.count, 6)
            if end == 6, bytes[5] == cr, bytes.count > 6, bytes[6] == lf { end = 7 }
            bytes.removeFirst(end)
        }
        let separator = delimiter ?? detectDelimiter(bytes)

        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var fieldWasQuoted = false
        var line = 1
        var quoteLine = 1

        func endField() throws {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            fieldWasQuoted = false
            guard row.count <= maxColumns else {
                throw ConversionError.dataLimit("line \(line) has more than \(maxColumns) columns")
            }
        }
        func endRow() throws {
            let blank = row.isEmpty && field.isEmpty && !fieldWasQuoted
            try endField()
            if !blank { rows.append(row) }
            row = []
            guard rows.count <= maxRows else { throw ConversionError.dataLimit("it has more than \(maxRows) rows") }
        }

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if inQuotes {
                if byte == quote {
                    if index < bytes.count && bytes[index] == quote {
                        field.append(quote)
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    if byte == lf { line += 1 }
                    field.append(byte)
                }
                continue
            }
            switch byte {
            case quote where field.isEmpty && !fieldWasQuoted:
                inQuotes = true
                fieldWasQuoted = true
                quoteLine = line
            case separator:
                try endField()
            case cr:
                try endRow()
                if index < bytes.count && bytes[index] == lf { index += 1 }
                line += 1
            case lf:
                try endRow()
                line += 1
            default:
                field.append(byte) // a stray quote mid-field is kept as written
            }
        }
        guard !inQuotes else {
            throw ConversionError.invalidData("a quoted field that starts on line \(quoteLine) is never closed")
        }
        if !field.isEmpty || !row.isEmpty || fieldWasQuoted { try endRow() }
        return rows
    }

    /// Picks `;` when the first line has more semicolons than commas outside quotes.
    static func detectDelimiter(_ bytes: [UInt8]) -> UInt8 {
        var commas = 0, semicolons = 0, inQuotes = false
        for byte in bytes {
            if byte == quote { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if byte == cr || byte == lf { break }
            if byte == comma { commas += 1 }
            if byte == semicolon { semicolons += 1 }
        }
        return semicolons > commas ? semicolon : comma
    }

    /// Writes rows with CRLF line endings, quoting only fields that need it.
    static func write(_ rows: [[DataValue]], delimiter: UInt8) -> Data {
        let separator = String(UnicodeScalar(delimiter))
        var out = ""
        for row in rows {
            if row.count == 1, cellText(row[0]).isEmpty {
                out += "\"\"\r\n" // a bare empty line would be read back as no row at all
                continue
            }
            out += row.map { escape(cellText($0), separator: separator) }.joined(separator: separator)
            out += "\r\n"
        }
        return Data(out.utf8)
    }

    static func cellText(_ value: DataValue) -> String {
        switch value {
        case .null: ""
        case .bool(let flag): flag ? "true" : "false"
        case .number(let text), .string(let text): text
        case .array, .object: JSONWriter.compact(value)
        }
    }

    private static func escape(_ text: String, separator: String) -> String {
        let special = separator.unicodeScalars.first!
        let needsQuotes = text.unicodeScalars.contains { $0 == special || $0 == "\"" || $0 == "\n" || $0 == "\r" }
            || text.hasPrefix(" ") || text.hasSuffix(" ")
        return needsQuotes ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }
}
