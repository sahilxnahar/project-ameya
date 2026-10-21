import Foundation

extension HTMLSanitizer {
    /// A small HTML tokenizer following the HTML5 rules for tags, attributes, comments and raw
    /// text closely enough that the sanitizer never sees a tag WebKit wouldn't, and the reverse.
    /// Comments, doctypes, processing instructions and CDATA are skipped; a `<` that doesn't
    /// start a tag becomes `&lt;` text.
    struct Tokenizer {
        struct Attribute {
            var name: String
            var value: String
        }

        enum Token {
            case text(String)
            case startTag(String, [Attribute], selfClosing: Bool)
            case endTag(String)
            /// `<!DOCTYPE …>`: only whether there was one matters (it decides standards mode).
            case doctype
        }

        private let input: [Unicode.Scalar]
        private var index = 0

        init(_ input: [Unicode.Scalar]) {
            self.input = input
        }

        mutating func next() -> Token? {
            guard index < input.count else { return nil }
            guard input[index] == "<" else {
                var text = String.UnicodeScalarView()
                while index < input.count, input[index] != "<" {
                    text.append(input[index])
                    index += 1
                }
                return .text(String(text))
            }
            let following = index + 1 < input.count ? input[index + 1] : " "
            if following == "!" {
                if startsWith("<!--", at: index) {
                    index = position(of: "-->", from: index + 4).map { $0 + 3 } ?? input.count
                    return next()
                }
                let isDoctype = startsWith("<!doctype", at: index, caseInsensitive: true)
                skipPast(">")
                return isDoctype ? .doctype : next()
            }
            if following == "?" {
                skipPast(">")
                return next()
            }
            if following == "/" {
                let nameStart = index + 2
                guard nameStart < input.count, isLetter(input[nameStart]) else {
                    skipPast(">") // "</>" and "</ " are bogus comments
                    return next()
                }
                index = nameStart
                let name = readName()
                skipPast(">")
                return .endTag(name)
            }
            guard isLetter(following) else {
                index += 1
                return .text("&lt;")
            }
            index += 1
            let name = readName()
            guard let (attributes, selfClosing) = readAttributes() else {
                index = input.count // a tag cut off by the end of the file is dropped, as browsers do
                return nil
            }
            return .startTag(name, attributes, selfClosing: selfClosing)
        }

        /// Skips the content of a raw-text element and its end tag.
        mutating func skipRawText(until name: String) {
            _ = rawText(until: name)
        }

        /// The content of a raw-text element, up to its end tag, which is consumed too.
        mutating func rawText(until name: String) -> String {
            var search = index
            while let found = position(of: "</", from: search) {
                let afterName = found + 2 + name.unicodeScalars.count
                if startsWith("</" + name, at: found, caseInsensitive: true),
                   afterName >= input.count || isTagEnd(input[afterName]) {
                    let content = String(String.UnicodeScalarView(input[index..<found]))
                    index = afterName
                    skipPast(">")
                    return content
                }
                search = found + 2
            }
            let content = String(String.UnicodeScalarView(input[index...]))
            index = input.count
            return content
        }

        // MARK: Pieces

        private mutating func readName() -> String {
            var name = String.UnicodeScalarView()
            while index < input.count, !isWhitespace(input[index]), input[index] != "/", input[index] != ">" {
                name.append(contentsOf: String(input[index]).lowercased().unicodeScalars)
                index += 1
            }
            return String(name)
        }

        /// Attributes up to the closing `>`, first occurrence of each name winning; nil at end of input.
        private mutating func readAttributes() -> ([Attribute], Bool)? {
            var attributes: [Attribute] = []
            var seen: Set<String> = []
            var selfClosing = false
            while true {
                while index < input.count, isWhitespace(input[index]) || input[index] == "/" {
                    selfClosing = input[index] == "/" && index + 1 < input.count && input[index + 1] == ">"
                    index += 1
                }
                guard index < input.count else { return nil }
                if input[index] == ">" {
                    index += 1
                    return (attributes, selfClosing)
                }
                selfClosing = false
                var name = String.UnicodeScalarView()
                repeat {
                    name.append(contentsOf: String(input[index]).lowercased().unicodeScalars)
                    index += 1
                } while index < input.count && !isWhitespace(input[index]) && !["/", ">", "="].contains(input[index])
                while index < input.count, isWhitespace(input[index]) { index += 1 }
                var value = ""
                if index < input.count, input[index] == "=" {
                    index += 1
                    while index < input.count, isWhitespace(input[index]) { index += 1 }
                    guard index < input.count else { return nil }
                    var raw = String.UnicodeScalarView()
                    if input[index] == "\"" || input[index] == "'" {
                        let quote = input[index]
                        index += 1
                        while index < input.count, input[index] != quote {
                            raw.append(input[index])
                            index += 1
                        }
                        guard index < input.count else { return nil }
                        index += 1
                    } else {
                        while index < input.count, !isWhitespace(input[index]), input[index] != ">" {
                            raw.append(input[index])
                            index += 1
                        }
                    }
                    value = Self.decodeEntities(String(raw))
                }
                let attributeName = String(name)
                if seen.insert(attributeName).inserted {
                    attributes.append(Attribute(name: attributeName, value: value))
                }
            }
        }

        private mutating func skipPast(_ character: Unicode.Scalar) {
            while index < input.count, input[index] != character { index += 1 }
            index = min(index + 1, input.count)
        }

        private func position(of text: String, from start: Int) -> Int? {
            var position = start
            while position < input.count {
                if startsWith(text, at: position) { return position }
                position += 1
            }
            return nil
        }

        private func startsWith(_ text: String, at position: Int, caseInsensitive: Bool = false) -> Bool {
            let scalars = Array(text.unicodeScalars)
            guard position + scalars.count <= input.count else { return false }
            for (offset, scalar) in scalars.enumerated() {
                let candidate = input[position + offset]
                if caseInsensitive {
                    guard String(candidate).lowercased() == String(scalar).lowercased() else { return false }
                } else {
                    guard candidate == scalar else { return false }
                }
            }
            return true
        }

        private func isLetter(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
        }

        private func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
            scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}"
        }

        private func isTagEnd(_ scalar: Unicode.Scalar) -> Bool {
            isWhitespace(scalar) || scalar == "/" || scalar == ">"
        }

        /// Decodes numeric character references and the common named ones. Whatever isn't decoded
        /// stays literal; the sanitizer re-escapes values, so WebKit reads exactly this string.
        static func decodeEntities(_ value: String) -> String {
            guard value.contains("&") else { return value }
            let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
                                           "colon": ":", "sol": "/", "tab": "\t", "newline": "\n", "lpar": "(", "rpar": ")",
                                           "period": ".", "comma": ","]
            let scalars = Array(value.unicodeScalars)
            var result = String.UnicodeScalarView()
            var index = 0
            while index < scalars.count {
                guard scalars[index] == "&" else {
                    result.append(scalars[index])
                    index += 1
                    continue
                }
                var end = index + 1
                var numeric = false, hex = false
                if end < scalars.count, scalars[end] == "#" {
                    numeric = true
                    end += 1
                    if end < scalars.count, scalars[end] == "x" || scalars[end] == "X" { hex = true; end += 1 }
                }
                let digitsStart = end
                while end < scalars.count, end - digitsStart < 32,
                      numeric ? (hex ? scalars[end].properties.isASCIIHexDigit : ("0"..."9").contains(scalars[end]))
                              : (scalars[end].properties.isAlphabetic && scalars[end].isASCII) {
                    end += 1
                }
                let body = String(String.UnicodeScalarView(scalars[digitsStart..<end]))
                let decoded: String? = if numeric {
                    UInt32(body, radix: hex ? 16 : 10).flatMap(Unicode.Scalar.init).map { String($0) } ?? (body.isEmpty ? nil : "\u{FFFD}")
                } else {
                    named[body.lowercased()]
                }
                guard let decoded else {
                    result.append(scalars[index])
                    index += 1
                    continue
                }
                result.append(contentsOf: decoded.unicodeScalars)
                index = end < scalars.count && scalars[end] == ";" ? end + 1 : end
            }
            return String(result)
        }
    }
}
