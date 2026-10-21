import AmeyaCore
import Foundation

/// A JSON-like value that keeps object keys in their original order, so table columns keep
/// their order on the way through. Numbers keep their source text, so big integers and exact
/// decimals are never rounded by a trip through `Double`.
indirect enum DataValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([DataValue])
    case object([Field])

    struct Field: Equatable, Sendable {
        var key: String
        var value: DataValue
    }

    var isContainer: Bool {
        switch self {
        case .array, .object: true
        default: false
        }
    }

    /// Reads a table cell the way a person would: numbers and true/false become typed values,
    /// empty cells become null. Numbers with leading zeros (ZIP codes, IDs) or more than
    /// 15 digits (card and account numbers) stay text, because a spreadsheet would mangle them.
    static func inferred(from cell: String) -> DataValue {
        if cell.isEmpty { return .null }
        switch cell.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: break
        }
        return isPlainNumber(cell) ? .number(cell) : .string(cell)
    }

    /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?` with at most 15 significant digits.
    static func isPlainNumber(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var index = 0
        var digits = 0
        func isDigit(_ i: Int) -> Bool { i < bytes.count && (0x30...0x39).contains(bytes[i]) }
        if index < bytes.count && bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard isDigit(index) else { return false }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
            if isDigit(index) { return false } // leading zero: keep as text
        } else {
            while isDigit(index) { index += 1; digits += 1 }
        }
        if index < bytes.count && bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard isDigit(index) else { return false }
            while isDigit(index) { index += 1; digits += 1 }
        }
        if index < bytes.count && (bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E")) {
            index += 1
            if index < bytes.count && (bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-")) { index += 1 }
            guard isDigit(index) else { return false }
            while isDigit(index) { index += 1 }
        }
        return index == bytes.count && digits <= 15
    }
}

/// A strict RFC 8259 JSON reader that keeps key order and number text.
struct JSONReader {
    static let maxDepth = 512

    private let bytes: [UInt8]
    private var index = 0

    static func parse(_ text: String) throws -> DataValue {
        var reader = JSONReader(bytes: Array(text.utf8))
        let value = try reader.value(depth: 0)
        reader.skipWhitespace()
        guard reader.index == reader.bytes.count else { throw reader.fail("there is extra text after the JSON value") }
        return value
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")

    private mutating func value(depth: Int) throws -> DataValue {
        guard depth <= Self.maxDepth else {
            throw ConversionError.dataLimit("it is nested more than \(Self.maxDepth) levels deep")
        }
        skipWhitespace()
        guard index < bytes.count else { throw fail("the file ends before the JSON is complete") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try object(depth: depth)
        case UInt8(ascii: "["): return try array(depth: depth)
        case Self.quote: return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return .number(try number())
        }
    }

    private mutating func object(depth: Int) throws -> DataValue {
        index += 1
        var fields: [DataValue.Field] = []
        var positions: [String: Int] = [:]
        skipWhitespace()
        if consume(UInt8(ascii: "}")) { return .object([]) }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == Self.quote else { throw fail("expected a key in double quotes") }
            let key = try string()
            skipWhitespace()
            guard consume(UInt8(ascii: ":")) else { throw fail("expected ':' after a key") }
            let value = try self.value(depth: depth + 1)
            if let position = positions[key] {
                fields[position].value = value // the last duplicate wins, as in most readers
            } else {
                positions[key] = fields.count
                fields.append(.init(key: key, value: value))
            }
            skipWhitespace()
            if consume(UInt8(ascii: ",")) { continue }
            guard consume(UInt8(ascii: "}")) else { throw fail("expected ',' or '}'") }
            return .object(fields)
        }
    }

    private mutating func array(depth: Int) throws -> DataValue {
        index += 1
        var items: [DataValue] = []
        skipWhitespace()
        if consume(UInt8(ascii: "]")) { return .array([]) }
        while true {
            items.append(try value(depth: depth + 1))
            skipWhitespace()
            if consume(UInt8(ascii: ",")) { continue }
            guard consume(UInt8(ascii: "]")) else { throw fail("expected ',' or ']'") }
            return .array(items)
        }
    }

    private mutating func string() throws -> String {
        index += 1
        var buffer: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case Self.quote:
                return String(decoding: buffer, as: UTF8.self)
            case Self.backslash:
                guard index < bytes.count else { break }
                let escape = bytes[index]
                index += 1
                switch escape {
                case Self.quote, Self.backslash, UInt8(ascii: "/"): buffer.append(escape)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800..<0xDC00).contains(code), index + 1 < bytes.count,
                       bytes[index] == Self.backslash, bytes[index + 1] == UInt8(ascii: "u") {
                        let saved = index
                        index += 2
                        let low = try hex4()
                        if (0xDC00..<0xE000).contains(low) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            index = saved
                        }
                    }
                    let scalar = Unicode.Scalar(code) ?? "\u{FFFD}" // lone surrogates
                    buffer.append(contentsOf: Array(String(scalar).utf8))
                default:
                    throw fail("a string contains an unknown escape")
                }
            case 0..<0x20:
                throw fail("a string contains an unescaped control character")
            default:
                buffer.append(byte)
            }
        }
        throw fail("a string is never closed")
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count,
              let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
            throw fail("a \\u escape needs four hex digits")
        }
        index += 4
        return value
    }

    private mutating func number() throws -> String {
        let start = index
        func digits() -> Int {
            let from = index
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            return index - from
        }
        _ = consume(UInt8(ascii: "-"))
        if consume(UInt8(ascii: "0")) {
            // A leading zero must stand alone.
        } else if digits() == 0 {
            throw fail("unexpected character")
        }
        if consume(UInt8(ascii: ".")), digits() == 0 { throw fail("a number has no digits after '.'") }
        if consume(UInt8(ascii: "e")) || consume(UInt8(ascii: "E")) {
            _ = consume(UInt8(ascii: "+")) || consume(UInt8(ascii: "-"))
            if digits() == 0 { throw fail("a number has an empty exponent") }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func literal(_ word: String) throws {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
            throw fail("unexpected character")
        }
        index += expected.count
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    fileprivate mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private func fail(_ reason: String) -> ConversionError {
        let line = bytes[..<min(index, bytes.count)].reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
        return .invalidData("it isn't valid JSON: \(reason) (line \(line))")
    }
}

/// Writes JSON pretty-printed with two-space indents and sorted keys, so output is stable and diffable.
enum JSONWriter {
    static func write(_ value: DataValue) -> Data {
        var out = ""
        append(value, indent: 0, pretty: true, to: &out)
        out += "\n"
        return Data(out.utf8)
    }

    /// One-line JSON, for nested values that have to fit in a single table cell.
    static func compact(_ value: DataValue) -> String {
        var out = ""
        append(value, indent: 0, pretty: false, to: &out)
        return out
    }

    private static func append(_ value: DataValue, indent: Int, pretty: Bool, to out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .number(let text): out += text
        case .string(let text): appendQuoted(text, to: &out)
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "["
            for (offset, item) in items.enumerated() {
                if offset > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: "  ", count: indent + 1) }
                append(item, indent: indent + 1, pretty: pretty, to: &out)
            }
            if pretty { out += "\n" + String(repeating: "  ", count: indent) }
            out += "]"
        case .object(let fields):
            guard !fields.isEmpty else { out += "{}"; return }
            out += "{"
            for (offset, field) in fields.sorted(by: { $0.key < $1.key }).enumerated() {
                if offset > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: "  ", count: indent + 1) }
                appendQuoted(field.key, to: &out)
                out += pretty ? ": " : ":"
                append(field.value, indent: indent + 1, pretty: pretty, to: &out)
            }
            if pretty { out += "\n" + String(repeating: "  ", count: indent) }
            out += "}"
        }
    }

    static func appendQuoted(_ text: String, to out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}
