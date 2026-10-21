import Foundation

/// Rewrites untrusted HTML so that the system's HTML reader (WebKit) has nothing to load:
/// no scripts, frames, plug-ins, style sheet links, `<base>` or `<meta http-equiv>`, no event
/// handlers, and no `src`, `href`, `srcset`, `poster`, `background`, CSS `url()` or `@import`
/// that points anywhere but a `data:` URI or a `#fragment` inside the document. Link text is
/// kept; `<a href>` keeps `http:`, `https:` and `mailto:` targets, which are metadata only.
///
/// The HTML is tokenized here and every tag written back from the parsed pieces, so what
/// WebKit sees is exactly what was checked: text never contains a raw `<`, comments and
/// processing instructions are dropped, and attribute values are decoded before they are
/// judged and re-escaped after.
enum HTMLSanitizer {
    /// Removed with everything inside them.
    static let droppedWithContent: Set<String> = ["script", "iframe", "object", "applet", "frameset", "frame",
                                                  "noscript", "noembed", "noframes", "xmp", "plaintext", "template", "portal"]
    /// Removed, keeping what's inside (or void).
    static let droppedTags: Set<String> = ["embed", "link", "base", "param", "source", "track"]
    /// Attributes whose value is a URL that may be fetched.
    static let urlAttributes: Set<String> = ["src", "href", "srcset", "imagesrcset", "poster", "background", "lowsrc",
                                             "dynsrc", "data", "action", "formaction", "cite", "longdesc", "usemap",
                                             "codebase", "archive", "classid", "manifest", "profile", "ping", "icon"]

    /// The sanitized HTML, and whether anything that would load from outside was removed.
    /// For WebKit, a `<meta>` turning off DNS prefetching for the kept links is added in front.
    static func sanitize(_ html: String, forWebKit: Bool = true) -> (html: String, removed: Bool) {
        var tokenizer = Tokenizer(Array(html.replacingOccurrences(of: "\0", with: "").unicodeScalars))
        var output = ""
        var removed = false
        var sawDoctype = false
        while let token = tokenizer.next() {
            switch token {
            case .doctype:
                sawDoctype = true
            case .text(let text):
                output += text
            case .endTag(let name):
                guard !droppedTags.contains(name), !droppedWithContent.contains(name) else { continue }
                output += "</\(name)>"
            case .startTag(let name, let attributes, let selfClosing):
                if droppedWithContent.contains(name) {
                    removed = true
                    if !selfClosing { tokenizer.skipRawText(until: name) }
                    continue
                }
                if droppedTags.contains(name) {
                    removed = true
                    continue
                }
                if name == "meta", let equiv = attributes.first(where: { $0.name == "http-equiv" }) {
                    // Refresh can load a page; content types and the rest only restate what
                    // was already decided (the text is UTF-8 by now), so they go quietly.
                    if equiv.value.lowercased().contains("refresh") { removed = true }
                    continue
                }
                if name == "style" {
                    let css = tokenizer.rawText(until: name)
                    // Inside SVG or MathML a <style> holds markup, not CSS: not kept.
                    guard !css.contains("<"), let (clean, changed) = sanitizeStyle(css) else {
                        removed = true
                        continue
                    }
                    removed = removed || changed
                    output += "<style>\(clean)</style>"
                    continue
                }
                var tag = "<" + name
                for attribute in attributes {
                    guard let value = keptValue(of: attribute, in: name, removed: &removed) else { continue }
                    tag += " \(attribute.name)=\"\(escape(value))\""
                }
                output += tag + (selfClosing ? "/>" : ">")
            }
        }
        let prefix = (sawDoctype ? "<!DOCTYPE html>" : "")
            + (forWebKit ? "<meta http-equiv=\"x-dns-prefetch-control\" content=\"off\">" : "")
        return (prefix + output, removed)
    }

    /// The value to write for an attribute, or nil to leave it out.
    private static func keptValue(of attribute: Tokenizer.Attribute, in element: String, removed: inout Bool) -> String? {
        let name = attribute.name
        let local = name.split(separator: ":").last.map(String.init) ?? name
        guard isPlainName(name) else { return nil }
        if local.hasPrefix("on") {
            removed = true
            return nil
        }
        if local == "style" {
            guard let (clean, changed) = sanitizeStyle(attribute.value) else {
                removed = true
                return nil
            }
            removed = removed || changed
            return clean
        }
        guard urlAttributes.contains(local) else { return attribute.value }
        let url = compactURL(attribute.value)
        if url.isEmpty || url.hasPrefix("#") { return attribute.value }
        if local == "srcset" || local == "imagesrcset" || local == "ping" || local == "archive" {
            removed = true
            return nil
        }
        if url.hasPrefix("data:") && local != "href" && local != "action" && local != "formaction" {
            return attribute.value
        }
        if local == "href", element == "a" || element == "area",
           url.hasPrefix("http:") || url.hasPrefix("https:") || url.hasPrefix("mailto:") {
            return attribute.value
        }
        removed = true
        return nil
    }

    /// A URL as a browser reads it: ASCII whitespace and control characters removed, lowercased.
    static func compactURL(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F })).lowercased()
    }

    private static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" || $0 == ":" || $0 == "."
        }
    }

    /// CSS with its references removed, or nil when CSS escapes (`u\72l(`) hide one that the
    /// plain-text pass can't see; such a style is dropped whole.
    static func sanitizeStyle(_ css: String) -> (String, Bool)? {
        let (clean, changed) = sanitizeCSS(css)
        guard clean.contains("\\") else { return (clean, changed) }
        return sanitizeCSS(unescapeCSS(clean)).1 ? nil : (clean, changed)
    }

    /// CSS escapes resolved (`\75` and `\u` both become `u`), for checking only.
    static func unescapeCSS(_ css: String) -> String {
        let scalars = Array(css.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "\\", index + 1 < scalars.count else {
                output.append(scalars[index])
                index += 1
                continue
            }
            index += 1
            var hex = ""
            while index < scalars.count, hex.count < 6, scalars[index].properties.isASCIIHexDigit {
                hex.unicodeScalars.append(scalars[index])
                index += 1
            }
            if hex.isEmpty {
                if scalars[index] != "\n" { output.append(scalars[index]) }
                index += 1
            } else {
                output.append(UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init) ?? "\u{FFFD}")
                if index < scalars.count, [" ", "\t", "\n"].contains(scalars[index]) { index += 1 }
            }
        }
        return String(output)
    }

    /// Replaces every `url()` and `src()` that isn't a `data:` URI or `#fragment` with `none`,
    /// disables `image-set()` and similar functions, and removes `@import` rules.
    static func sanitizeCSS(_ css: String) -> (String, Bool) {
        let scalars = Array(css.unicodeScalars)
        var output = String.UnicodeScalarView()
        var changed = false
        var index = 0
        func matches(_ word: String, at position: Int) -> Bool {
            let letters = Array(word.unicodeScalars)
            guard position + letters.count <= scalars.count else { return false }
            for (offset, letter) in letters.enumerated()
            where Character(scalars[position + offset]).lowercased() != Character(letter).lowercased() {
                return false
            }
            return true
        }
        let blockedFunctions = ["-webkit-image-set(", "image-set(", "-webkit-cross-fade(", "cross-fade(", "image(", "element("]
        while index < scalars.count {
            let atWordStart = index == 0 || !isIdentifier(scalars[index - 1])
            if atWordStart, matches("@import", at: index) {
                while index < scalars.count, scalars[index] != ";" { index += 1 }
                index += 1
                changed = true
                continue
            }
            if atWordStart, matches("url(", at: index) || matches("src(", at: index) {
                var end = index + 4
                while end < scalars.count, scalars[end] == " " || scalars[end] == "\t" || scalars[end] == "\n" { end += 1 }
                var argument = ""
                if end < scalars.count, scalars[end] == "\"" || scalars[end] == "'" {
                    let quote = scalars[end]
                    end += 1
                    while end < scalars.count, scalars[end] != quote { argument.unicodeScalars.append(scalars[end]); end += 1 }
                    end += 1
                    while end < scalars.count, scalars[end] != ")" { end += 1 }
                } else {
                    while end < scalars.count, scalars[end] != ")" { argument.unicodeScalars.append(scalars[end]); end += 1 }
                }
                end = min(end + 1, scalars.count)
                let url = compactURL(argument)
                if url.hasPrefix("data:") || url.hasPrefix("#") {
                    output.append(contentsOf: scalars[index..<end])
                } else {
                    output.append(contentsOf: "none".unicodeScalars)
                    changed = true
                }
                index = end
                continue
            }
            if atWordStart, let blocked = blockedFunctions.first(where: { matches($0, at: index) }) {
                // The whole call, up to its matching parenthesis, becomes `none`.
                var end = index + blocked.unicodeScalars.count
                var depth = 1
                while end < scalars.count, depth > 0 {
                    if scalars[end] == "(" { depth += 1 } else if scalars[end] == ")" { depth -= 1 }
                    end += 1
                }
                output.append(contentsOf: "none".unicodeScalars)
                index = end
                changed = true
                continue
            }
            output.append(scalars[index])
            index += 1
        }
        return (String(output), changed)
    }

    private static func isIdentifier(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_"
    }

    static func escape(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "\"": result += "&quot;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
