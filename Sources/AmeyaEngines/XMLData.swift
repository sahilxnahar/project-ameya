import AmeyaCore
import Foundation

/// Reads any XML document into a tree: each element becomes an object keyed by its name,
/// attributes become "@name" keys, text becomes "#text", and repeated child elements become
/// arrays. An element with only text becomes a plain string. Values stay text.
final class XMLTreeReader: NSObject, XMLParserDelegate {
    static let maxDepth = 512
    static let maxElements = 5_000_000

    private final class Element {
        let name: String
        var attributes: [DataValue.Field]
        var order: [String] = []
        var children: [String: [DataValue]] = [:]
        var text = ""

        init(name: String, attributes: [DataValue.Field]) {
            self.name = name
            self.attributes = attributes
        }

        func add(_ name: String, _ value: DataValue) {
            if children[name] == nil { order.append(name) }
            children[name, default: []].append(value)
        }

        var value: DataValue {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if attributes.isEmpty && order.isEmpty { return .string(text) }
            var fields = attributes
            for name in order {
                let values = children[name] ?? []
                fields.append(.init(key: name, value: values.count == 1 ? values[0] : .array(values)))
            }
            if !text.isEmpty { fields.append(.init(key: "#text", value: .string(text))) }
            return .object(fields)
        }
    }

    private var stack: [Element] = []
    private var root: DataValue?
    private var elements = 0
    private var failure: ConversionError?

    static func read(_ data: Data) throws -> DataValue {
        // Entity declarations enable "billion laughs" expansion and external lookups; real data files don't need them.
        if data.range(of: Data("<!ENTITY".utf8)) != nil {
            throw ConversionError.invalidData("XML files that declare their own entities aren't supported, for safety")
        }
        let reader = XMLTreeReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let parsed = parser.parse()
        if let failure = reader.failure { throw failure }
        guard parsed, let root = reader.root else {
            throw ConversionError.invalidData("it isn't well-formed XML (problem near line \(parser.lineNumber))")
        }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        elements += 1
        if stack.count >= Self.maxDepth || elements > Self.maxElements {
            failure = .dataLimit(stack.count >= Self.maxDepth
                ? "it is nested more than \(Self.maxDepth) levels deep"
                : "it has more than \(Self.maxElements) elements")
            parser.abortParsing()
            return
        }
        let fields = attributes.keys.sorted().map { DataValue.Field(key: "@" + $0, value: .string(attributes[$0]!)) }
        stack.append(Element(name: elementName, attributes: fields))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard let element = stack.popLast() else { return }
        if let parent = stack.last {
            parent.add(element.name, element.value)
        } else {
            root = .object([.init(key: element.name, value: element.value)])
        }
    }
}

/// Writes a tree as XML, the reverse of `XMLTreeReader`: "@name" keys become attributes,
/// "#text" becomes text, and arrays become repeated elements.
enum XMLTreeWriter {
    static func write(_ value: DataValue) -> (data: Data, namesAdjusted: Bool) {
        var writer = State()
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        if case .object(let fields) = value, fields.count == 1, !fields[0].key.hasPrefix("@"),
           fields[0].key != "#text", !isArray(fields[0].value) {
            writer.element(fields[0].key, fields[0].value, indent: 0, into: &out)
        } else {
            writer.element("root", value, indent: 0, into: &out)
        }
        return (Data(out.utf8), writer.namesAdjusted)
    }

    private static func isArray(_ value: DataValue) -> Bool {
        if case .array = value { true } else { false }
    }

    private struct State {
        var namesAdjusted = false

        mutating func element(_ rawName: String, _ value: DataValue, indent: Int, into out: inout String) {
            let name = xmlName(rawName)
            let pad = String(repeating: "  ", count: indent)
            switch value {
            case .null:
                out += "\(pad)<\(name)/>\n"
            case .array(let items):
                out += "\(pad)<\(name)>\n"
                for item in items { element("item", item, indent: indent + 1, into: &out) }
                out += "\(pad)</\(name)>\n"
            case .object(let fields):
                var attributes = ""
                var text: String?
                var children: [DataValue.Field] = []
                for field in fields {
                    if field.key.hasPrefix("@"), field.key.count > 1, !field.value.isContainer {
                        attributes += " \(xmlName(String(field.key.dropFirst())))=\"\(escape(DelimitedText.cellText(field.value), attribute: true))\""
                    } else if field.key == "#text", !field.value.isContainer {
                        text = DelimitedText.cellText(field.value)
                    } else {
                        children.append(field)
                    }
                }
                if children.isEmpty {
                    out += text.map { "\(pad)<\(name)\(attributes)>\(escape($0))</\(name)>\n" } ?? "\(pad)<\(name)\(attributes)/>\n"
                    return
                }
                out += "\(pad)<\(name)\(attributes)>\n"
                if let text { out += "\(pad)  \(escape(text))\n" }
                for child in children {
                    if case .array(let items) = child.value {
                        for item in items { element(child.key, item, indent: indent + 1, into: &out) }
                    } else {
                        element(child.key, child.value, indent: indent + 1, into: &out)
                    }
                }
                out += "\(pad)</\(name)>\n"
            case .bool, .number, .string:
                out += "\(pad)<\(name)>\(escape(DelimitedText.cellText(value)))</\(name)>\n"
            }
        }

        /// Replaces characters that aren't allowed in XML names with "_".
        mutating func xmlName(_ raw: String) -> String {
            var name = ""
            for (offset, scalar) in raw.unicodeScalars.enumerated() {
                let isStart = scalar.properties.isAlphabetic || scalar == "_"
                let isName = isStart || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "."
                if offset == 0 && !isStart {
                    name += "_"
                    if isName { name.unicodeScalars.append(scalar) }
                } else {
                    name.unicodeScalars.append(isName ? scalar : "_")
                }
            }
            if name.isEmpty { name = "_" }
            if name != raw { namesAdjusted = true }
            return name
        }
    }

    /// Escapes markup characters and drops characters XML 1.0 can't contain at all.
    static func escape(_ text: String, attribute: Bool = false) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            case "\n" where attribute: out += "&#10;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20 || (0xFFFE...0xFFFF).contains(scalar.value): continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
