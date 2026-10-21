import AmeyaCore
import Foundation

/// Property lists (XML, binary and old-style text in; XML out) through PropertyListSerialization.
enum PropertyListData {
    static let maxDepth = 512
    /// Binary property lists can point many times at one shared array or dictionary, so a
    /// small file can stand for a huge tree once expanded. Values are counted as they're copied.
    static let maxNodes = 5_000_000

    /// Returns the tree, and whether dates or binary data had to be turned into text.
    static func read(_ data: Data, maxNodes: Int = maxNodes) throws -> (DataValue, simplified: Bool) {
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw ConversionError.invalidData("it isn't a valid property list")
        }
        var simplified = false
        var budget = maxNodes
        let value = try convert(plist, depth: 0, budget: &budget, simplified: &simplified)
        return (value, simplified)
    }

    private static func convert(_ object: Any, depth: Int, budget: inout Int, simplified: inout Bool) throws -> DataValue {
        guard depth <= maxDepth else { throw ConversionError.dataLimit("it is nested more than \(maxDepth) levels deep") }
        budget -= 1
        guard budget >= 0 else { throw ConversionError.dataLimit("it expands to more than \(maxNodes.formatted()) values") }
        switch object {
        case let dictionary as [String: Any]:
            return .object(try dictionary.keys.sorted().map {
                DataValue.Field(key: $0, value: try convert(dictionary[$0]!, depth: depth + 1, budget: &budget, simplified: &simplified))
            })
        case let array as [Any]:
            return .array(try array.map { try convert($0, depth: depth + 1, budget: &budget, simplified: &simplified) })
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) {
                let double = number.doubleValue
                return double.isFinite ? .number("\(double)") : .string("\(double)")
            }
            return .number(number.stringValue)
        case let date as Date:
            simplified = true
            return .string(date.formatted(.iso8601))
        case let data as Data:
            simplified = true
            return .string(data.base64EncodedString())
        default:
            throw ConversionError.invalidData("it contains a value property lists don't allow")
        }
    }

    /// Writes an XML property list. Returns whether null values had to be left out.
    static func write(_ value: DataValue) throws -> (Data, nullsRemoved: Bool) {
        var nullsRemoved = false
        guard let plist = object(value, nullsRemoved: &nullsRemoved) else {
            throw ConversionError.invalidData("there is nothing to write: the whole file is null")
        }
        do {
            return (try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), nullsRemoved)
        } catch {
            throw ConversionError.encodeFailed(.plist)
        }
    }

    private static func object(_ value: DataValue, nullsRemoved: inout Bool) -> Any? {
        switch value {
        case .null:
            nullsRemoved = true
            return nil
        case .bool(let flag): return NSNumber(value: flag)
        case .number(let text):
            if let integer = Int64(text) { return NSNumber(value: integer) }
            if let integer = UInt64(text) { return NSNumber(value: integer) }
            return NSNumber(value: Double(text) ?? 0)
        case .string(let text): return text
        case .array(let items):
            return items.compactMap { object($0, nullsRemoved: &nullsRemoved) }
        case .object(let fields):
            var dictionary: [String: Any] = [:]
            for field in fields {
                dictionary[field.key] = object(field.value, nullsRemoved: &nullsRemoved)
            }
            return dictionary
        }
    }
}

/// A conservative YAML 1.2 writer: block style, two-space indents, and any string that could
/// be read back as something else (yes, no, null, 1.0, "a: b", leading symbols) double-quoted.
enum YAMLWriter {
    static func write(_ value: DataValue) -> Data {
        var out = ""
        switch value {
        case .object(let fields) where !fields.isEmpty: mapping(fields, indent: 0, into: &out)
        case .array(let items) where !items.isEmpty: sequence(items, indent: 0, into: &out)
        default: out = scalar(value) + "\n"
        }
        return Data(out.utf8)
    }

    private static func mapping(_ fields: [DataValue.Field], indent: Int, into out: inout String) {
        let pad = String(repeating: " ", count: indent)
        for field in fields {
            out += pad + string(field.key) + ":"
            nested(field.value, indent: indent + 2, into: &out)
        }
    }

    private static func sequence(_ items: [DataValue], indent: Int, into out: inout String) {
        let pad = String(repeating: " ", count: indent)
        for item in items {
            out += pad + "-"
            switch item {
            case .object(let fields) where !fields.isEmpty:
                // The first key goes on the dash line: "- name: Ann".
                var block = ""
                mapping(fields, indent: indent + 2, into: &block)
                out += " " + block.dropFirst(indent + 2)
            case .array(let inner) where !inner.isEmpty:
                var block = ""
                sequence(inner, indent: indent + 2, into: &block)
                out += " " + block.dropFirst(indent + 2)
            default:
                out += " " + scalar(item) + "\n"
            }
        }
    }

    private static func nested(_ value: DataValue, indent: Int, into out: inout String) {
        switch value {
        case .object(let fields) where !fields.isEmpty:
            out += "\n"
            mapping(fields, indent: indent, into: &out)
        case .array(let items) where !items.isEmpty:
            out += "\n"
            sequence(items, indent: indent, into: &out)
        default:
            out += " " + scalar(value) + "\n"
        }
    }

    static func scalar(_ value: DataValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let flag): flag ? "true" : "false"
        case .number(let text): text
        case .string(let text): string(text)
        case .array: "[]"
        case .object: "{}"
        }
    }

    private static let reserved: Set<String> = [
        "true", "false", "yes", "no", "on", "off", "y", "n", "null", "nan", "inf", "infinity",
    ]

    /// Plain when it starts with a letter and holds only letters, digits, spaces and `_-./`; quoted otherwise.
    static func string(_ text: String) -> String {
        guard let first = text.unicodeScalars.first, first.properties.isAlphabetic,
              !text.hasSuffix(" "), !reserved.contains(text.lowercased()),
              text.unicodeScalars.allSatisfy({
                  $0.properties.isAlphabetic || ("0"..."9").contains($0) || " _-./".unicodeScalars.contains($0)
              }) else {
            return quoted(text)
        }
        return text
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
                || [0x2028, 0x2029, 0xFEFF].contains(scalar.value):
                out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
