import AppKit
import Foundation

/// Markdown → HTML, using Foundation's CommonMark parser (with GitHub-style tables and
/// strikethrough) and rendering its block structure to semantic HTML.
enum MarkdownRenderer {
    static func html(_ markdown: String, title: String = "Document") throws -> String {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let parsed = try AttributedString(markdown: markdown, options: options)
        var body = ""
        var open: [(intent: PresentationIntent.IntentType, close: String)] = [] // outermost first

        for (intent, range) in parsed.runs[\.presentationIntent] {
            let chain = Array((intent?.components ?? []).reversed())
            var common = 0
            while common < open.count, common < chain.count, open[common].intent == chain[common] { common += 1 }
            for element in open[common...].reversed() { body += element.close }
            open.removeSubrange(common...)
            for item in chain[common...] {
                let (openTag, closeTag) = tags(for: item, parent: open.last?.intent)
                body += openTag
                open.append((item, closeTag))
            }
            let inCode = chain.contains { if case .codeBlock = $0.kind { true } else { false } }
            body += inCode ? escape(String(parsed[range].characters)) : inline(parsed[range])
        }
        for element in open.reversed() { body += element.close }
        return document(title: title, body: body)
    }

    private static func tags(for item: PresentationIntent.IntentType, parent: PresentationIntent.IntentType?) -> (String, String) {
        switch item.kind {
        case .paragraph: return ("<p>", "</p>\n")
        case .header(let level): return ("<h\(level)>", "</h\(level)>\n")
        case .orderedList: return ("<ol>\n", "</ol>\n")
        case .unorderedList: return ("<ul>\n", "</ul>\n")
        case .listItem: return ("<li>", "</li>\n")
        case .codeBlock(let language):
            let attribute = language.map { " class=\"language-\(escape($0))\"" } ?? ""
            return ("<pre><code\(attribute)>", "</code></pre>\n")
        case .blockQuote: return ("<blockquote>\n", "</blockquote>\n")
        case .thematicBreak: return ("<hr>\n", "")
        case .table: return ("<table>\n", "</table>\n")
        case .tableHeaderRow: return ("<thead><tr>", "</tr></thead>\n")
        case .tableRow: return ("<tr>", "</tr>\n")
        case .tableCell:
            if case .tableHeaderRow = parent?.kind { return ("<th>", "</th>") }
            return ("<td>", "</td>")
        @unknown default: return ("<div>", "</div>\n")
        }
    }

    private static func inline(_ text: AttributedSubstring) -> String {
        var html = ""
        for run in text.runs {
            let content = String(text[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.lineBreak) { html += "<br>\n"; continue }
            if intent.contains(.softBreak) { html += "\n"; continue }
            if let image = run.imageURL {
                // A picture from a local file or an unknown scheme is left out; its text stays.
                guard isSafe(image, allowing: ["http", "https", "data"]) else {
                    html += escape(content)
                    continue
                }
                html += "<img src=\"\(escape(image.absoluteString))\" alt=\"\(escape(content))\">"
                continue
            }
            var piece = escape(content)
            if intent.contains(.code) { piece = "<code>\(piece)</code>" }
            if intent.contains(.emphasized) { piece = "<em>\(piece)</em>" }
            if intent.contains(.stronglyEmphasized) { piece = "<strong>\(piece)</strong>" }
            if intent.contains(.strikethrough) { piece = "<del>\(piece)</del>" }
            if let link = run.link, isSafe(link, allowing: ["http", "https", "mailto"]) { piece = "<a href=\"\(escape(link.absoluteString))\">\(piece)</a>" }
            html += piece
        }
        return html
    }

    /// Relative references, fragments, and URLs with one of `schemes`. Not `file:` or `javascript:`.
    static func isSafe(_ url: URL, allowing schemes: Set<String>) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            let text = url.absoluteString
            return !text.hasPrefix("/") && !text.hasPrefix("~") && !text.split(separator: "/").contains("..")
        }
        return schemes.contains(scheme)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func document(title: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        body { font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 12pt; line-height: 1.5; color: #1d1d1f; max-width: 46em; margin: 2em auto; }
        h1, h2, h3, h4 { line-height: 1.25; }
        code, pre { font-family: Menlo, "SF Mono", monospace; font-size: 10.5pt; }
        pre { background: #f5f5f7; padding: 0.8em; }
        blockquote { color: #555; border-left: 3px solid #ccc; margin-left: 0; padding-left: 1em; }
        table { border-collapse: collapse; }
        th, td { border: 1px solid #bbb; padding: 0.3em 0.6em; text-align: left; }
        </style></head>
        <body>
        \(body)</body></html>
        """
    }
}

/// Rich text → Markdown. Recovers headings from font size, lists from text lists, code from
/// monospaced fonts, tables from text tables, and bold, italic, code and links inline.
@MainActor
enum MarkdownWriter {
    static func markdown(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        var paragraphs: [NSRange] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            paragraphs.append(range)
        }
        let base = bodyFontSize(text)
        var blocks: [String] = []
        var list: [String] = []
        var code: [String] = []
        var table: (id: ObjectIdentifier, rows: [Int: [Int: String]])?
        var ordinals: [Int: Int] = [:]
        var topLevelOrdered: Bool?

        func flush() {
            if !list.isEmpty { blocks.append(list.joined(separator: "\n")); list = []; ordinals = [:]; topLevelOrdered = nil }
            if !code.isEmpty { blocks.append("```\n" + code.joined(separator: "\n") + "\n```"); code = [] }
            if let current = table { blocks.append(renderTable(current.rows)); table = nil }
        }

        for range in paragraphs {
            guard range.length > 0 else { flush(); continue }
            let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle

            if let cell = style?.textBlocks.last as? NSTextTableBlock {
                let id = ObjectIdentifier(cell.table)
                if table?.id != id { flush(); table = (id, [:]) }
                let content = inline(text, range).replacingOccurrences(of: "|", with: "\\|")
                table?.rows[cell.startingRow, default: [:]][cell.startingColumn] = content
                continue
            }
            if table != nil { flush() }

            // Lists come either with real text lists (HTML, RTF) or, after a trip through Apple's
            // DOCX writer, only as "\t•\t" / "\t1\t" marker text.
            let markerText = listMarker(string, range)
            let lists = style?.textLists ?? []
            if !lists.isEmpty || markerText != nil {
                if !code.isEmpty { flush() }
                let depth = max(lists.count - 1, 0)
                let ordered = lists.last.map { $0.markerFormat.rawValue.contains("decimal") }
                    ?? (markerText?.first?.isNumber ?? false)
                // A bullet list followed directly by a numbered one (or vice versa) is a new list.
                if depth == 0, let previous = topLevelOrdered, previous != ordered { flush() }
                if depth == 0 { topLevelOrdered = ordered }
                let marker: String
                if ordered {
                    ordinals[depth, default: 0] += 1
                    marker = "\(ordinals[depth]!)."
                } else {
                    marker = "-"
                }
                let item = inline(text, withoutListMarker(string, range))
                list.append(String(repeating: "  ", count: depth) + marker + " " + item)
                continue
            }
            if !list.isEmpty { flush() }

            if isMonospaced(text, range) {
                code.append(string.substring(with: range))
                continue
            }
            if !code.isEmpty { flush() }

            let line = inline(text, range)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let level = headingLevel(text, range, base: base) {
                blocks.append(String(repeating: "#", count: level) + " " + plainText(text, range))
            } else {
                blocks.append(line)
            }
        }
        flush()
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: Blocks

    private static func renderTable(_ rows: [Int: [Int: String]]) -> String {
        let columns = (rows.values.flatMap(\.keys).max() ?? 0) + 1
        let ordered = rows.keys.sorted().map { row in (0..<columns).map { rows[row]?[$0] ?? "" } }
        guard var header = ordered.first else { return "" }
        // Header cells are bold by definition; don't double up.
        header = header.map { cell in
            cell.hasPrefix("**") && cell.hasSuffix("**") && cell.count > 4 ? String(cell.dropFirst(2).dropLast(2)) : cell
        }
        var lines = ["| " + header.joined(separator: " | ") + " |",
                     "|" + Array(repeating: " --- |", count: columns).joined()]
        lines += ordered.dropFirst().map { "| " + $0.joined(separator: " | ") + " |" }
        return lines.joined(separator: "\n")
    }

    private static func headingLevel(_ text: NSAttributedString, _ range: NSRange, base: CGFloat) -> Int? {
        guard range.length < 200, let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return nil }
        let ratio = font.pointSize / max(base, 1)
        if ratio >= 1.6 { return 1 }
        if ratio >= 1.3 { return 2 }
        if ratio >= 1.12 { return 3 }
        return nil
    }

    /// The most common font size, weighted by characters.
    private static func bodyFontSize(_ text: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let size = (value as? NSFont)?.pointSize ?? 12
            counts[size, default: 0] += range.length
        }
        return counts.max { $0.value < $1.value }?.key ?? 12
    }

    private static func isMonospaced(_ text: NSAttributedString, _ range: NSRange) -> Bool {
        var mono = true
        text.enumerateAttribute(.font, in: range) { value, _, stop in
            if !((value as? NSFont)?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false) {
                mono = false
                stop.pointee = true
            }
        }
        return mono
    }

    /// The bullet or number of a list item written as text ("\t•\t", "\t2.\t"), if any.
    private static func listMarker(_ string: NSString, _ range: NSRange) -> String? {
        let paragraph = string.substring(with: range) as NSString
        let match = paragraph.range(of: "^\\t([•◦▪‣–\\-*]|[0-9]{1,3}[.)]?)\\t", options: .regularExpression)
        guard match.location == 0 else { return nil }
        return paragraph.substring(with: match).trimmingCharacters(in: .whitespaces)
    }

    /// Imported lists carry their marker in the text ("\t•\t", "\t1.\t"); Markdown adds its own.
    private static func withoutListMarker(_ string: NSString, _ range: NSRange) -> NSRange {
        let paragraph = string.substring(with: range) as NSString
        let marker = paragraph.range(of: "^\\t?[^\\t]{0,8}\\t", options: .regularExpression)
        guard marker.location == 0 else { return range }
        return NSRange(location: range.location + marker.length, length: range.length - marker.length)
    }

    // MARK: Inline

    private static func plainText(_ text: NSAttributedString, _ range: NSRange) -> String {
        text.attributedSubstring(from: range).string.trimmingCharacters(in: .whitespaces)
    }

    private static func inline(_ text: NSAttributedString, _ range: NSRange) -> String {
        var result = ""
        text.enumerateAttributes(in: range) { attributes, runRange, _ in
            let raw = (text.string as NSString).substring(with: runRange).replacingOccurrences(of: "\u{2028}", with: "  \n")
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            if traits.contains(.monoSpace) {
                result += wrap(raw, "`", escaping: false)
            } else {
                var piece = raw
                if traits.contains(.bold) && traits.contains(.italic) {
                    piece = wrap(raw, "***")
                } else if traits.contains(.bold) {
                    piece = wrap(raw, "**")
                } else if traits.contains(.italic) {
                    piece = wrap(raw, "*")
                } else {
                    piece = escape(raw)
                }
                if let link = attributes[.link] {
                    let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                    if !url.isEmpty { piece = "[\(piece)](\(url))" }
                }
                result += piece
            }
        }
        return result
    }

    /// Emphasis markers must hug the text, so leading and trailing spaces stay outside them.
    private static func wrap(_ text: String, _ marker: String, escaping: Bool = true) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return text }
        let leading = String(text.prefix { $0 == " " })
        let trailing = String(text.reversed().prefix { $0 == " " })
        return leading + marker + (escaping ? escape(trimmed) : trimmed) + marker + trailing
    }

    private static func escape(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if "\\`*_[]".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
}
