import Foundation

/// Small XHTML helpers shared by the EPUB reader and writer.
enum XHTML {
    /// Elements that may never have content. Written as `<br/>`, which is valid XHTML and HTML alike.
    static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]
    /// Removed entirely: active content, and anything that loads from outside the document.
    static let unsafeElements: Set<String> = ["script", "noscript", "style", "link", "meta", "iframe", "frame", "frameset",
                                              "object", "embed", "applet", "form", "base", "audio", "video", "template"]
    static let imageExtensions = ["image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/svg+xml": "svg", "image/webp": "webp"]

    /// Writes a node as well-formed XHTML: entities escaped, void elements self-closed, other
    /// empty elements written as a pair (a self-closed <div/> would swallow what follows in HTML),
    /// namespace prefixes dropped and comments left out.
    static func serialize(_ node: XMLNode) -> String {
        switch node.kind {
        case .text:
            return escape(node.stringValue ?? "", quotes: false)
        case .element:
            guard let element = node as? XMLElement, let name = element.localName, isName(name) else { return "" }
            var tag = "<" + name
            for attribute in element.attributes ?? [] {
                guard let attributeName = attribute.name, isName(attributeName) || attributeName.hasPrefix("xml:") else { continue }
                // Prefixed attributes (epub:type, xlink:href) would need namespace declarations.
                if attributeName.contains(":") && !attributeName.hasPrefix("xml:") { continue }
                if attributeName == "xmlns" { continue }
                tag += " \(attributeName)=\"\(escape(attribute.stringValue ?? ""))\""
            }
            if voidElements.contains(name) { return tag + "/>" }
            return tag + ">" + (element.children ?? []).map(serialize).joined() + "</\(name)>"
        default:
            return ""
        }
    }

    /// Escapes text for XML, dropping characters XML 1.0 can't hold at all.
    static func escape(_ text: String, quotes: Bool = true) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"" where quotes: result += "&quot;"
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF: continue
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Removes scripts and external content, event handler attributes and javascript: links.
    static func removeUnsafeContent(_ root: XMLElement) {
        for element in descendants(of: root) {
            if unsafeElements.contains(element.localName ?? "") {
                element.detach()
                continue
            }
            for attribute in element.attributes ?? [] {
                guard let name = attribute.name?.lowercased() else { continue }
                let value = (attribute.stringValue ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                if name.hasPrefix("on") || value.hasPrefix("javascript:") || value.hasPrefix("vbscript:") {
                    element.removeAttribute(forName: attribute.name ?? "")
                }
            }
            if voidElements.contains(element.localName ?? "") { element.setChildren(nil) }
        }
    }

    static func descendants(of root: XMLElement) -> [XMLElement] {
        var result: [XMLElement] = []
        var stack = [root]
        while let element = stack.popLast() {
            for case let child as XMLElement in element.children ?? [] {
                result.append(child)
                stack.append(child)
            }
        }
        return result
    }

    /// The heading level (1–6) of a heading element, or nil.
    static func headingLevel(_ node: XMLNode) -> Int? {
        guard node.kind == .element, let name = node.localName, name.count == 2, name.first == "h",
              let level = Int(name.dropFirst()), (1...6).contains(level) else { return nil }
        return level
    }

    /// Whether a node holds anything visible: any element, or non-blank text.
    static func hasContent(_ node: XMLNode) -> Bool {
        switch node.kind {
        case .element: true
        case .text: !(node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: false
        }
    }

    /// The text of a node with runs of whitespace collapsed, or nil when there is none.
    static func text(of node: XMLNode) -> String? {
        let words = (node.stringValue ?? "").split(whereSeparator: { $0.isWhitespace })
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Resolves an href inside the book. Returns nil for external URLs, absolute paths and
    /// paths that climb out of the book with `..`.
    static func resolve(_ href: String, from directory: String) -> String? {
        var reference = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = reference.firstIndex(where: { $0 == "#" || $0 == "?" }) { reference = String(reference[..<cut]) }
        guard !reference.isEmpty, !reference.hasPrefix("/"), !reference.contains(":") else { return nil }
        reference = reference.removingPercentEncoding ?? reference
        var parts = directory.split(separator: "/").map(String.init)
        for component in reference.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(String(component))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// The folder part of a path inside the book ("" at the top level).
    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func imageType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        default: "image/png"
        }
    }

    /// HTML named entities common in e-books, which XML doesn't know without the XHTML DTD.
    static let namedEntities: [String: Int] = [
        "nbsp": 160, "shy": 173, "copy": 169, "reg": 174, "trade": 8482, "deg": 176, "middot": 183, "times": 215,
        "ndash": 8211, "mdash": 8212, "lsquo": 8216, "rsquo": 8217, "sbquo": 8218, "ldquo": 8220, "rdquo": 8221,
        "bdquo": 8222, "hellip": 8230, "bull": 8226, "laquo": 171, "raquo": 187, "euro": 8364, "pound": 163,
        "sect": 167, "para": 182, "dagger": 8224, "Dagger": 8225, "thinsp": 8201, "ensp": 8194, "emsp": 8195,
        "zwj": 8205, "zwnj": 8204, "eacute": 233, "egrave": 232, "aacute": 225, "agrave": 224, "uuml": 252,
        "ouml": 246, "auml": 228, "szlig": 223, "ccedil": 231, "iacute": 237, "oacute": 243, "uacute": 250, "ntilde": 241,
    ]

    /// Rewrites known named entities as numeric character references.
    static func numericEntities(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        guard let pattern = try? NSRegularExpression(pattern: "&([A-Za-z]+);") else { return data }
        let result = NSMutableString(string: text)
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: result.length)).reversed() {
            let name = (text as NSString).substring(with: match.range(at: 1))
            if let code = namedEntities[name] { result.replaceCharacters(in: match.range, with: "&#\(code);") }
        }
        return Data((result as String).utf8)
    }

    /// The media type and bytes of a base64 `data:` URL.
    static func decodeDataURL(_ url: String) -> (String, Data)? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma].lowercased()
        guard header.hasSuffix(";base64"),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...]), options: .ignoreUnknownCharacters) else { return nil }
        return (String(header.dropLast(7)), data)
    }

    private static func isName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, CharacterSet.letters.contains(first) || first == "_" else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0) }
    }
}
