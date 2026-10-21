import AmeyaCore
import Foundation

/// Microsoft SAMI (.smi): HTML-like `<SYNC Start=ms><P Class=XX>text`. Each SYNC lasts until the next;
/// a SYNC holding only `&nbsp;` clears the screen. When a file holds several languages (P classes),
/// the first one is kept.
enum SAMIFormat {
    typealias Cue = SubtitleConverter.Cue

    private static let syncPattern = try! NSRegularExpression(
        pattern: #"<sync\b[^>]*?\bstart\s*=\s*["']?(-?\d+)[^>]*>"#, options: [.caseInsensitive]
    )
    private static let paragraphPattern = try! NSRegularExpression(
        pattern: #"<p\b([^>]*)>"#, options: [.caseInsensitive]
    )
    private static let classPattern = try! NSRegularExpression(
        pattern: #"class\s*=\s*["']?([\w-]+)"#, options: [.caseInsensitive]
    )

    static func parse(_ text: String) -> SubtitleConverter.Parsed {
        let source = text as NSString
        let syncs = syncPattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        var chosenClass: String?
        var entries: [(start: Int, text: String?)] = []
        var dropped = false
        for (index, sync) in syncs.enumerated() {
            guard let start = Int(source.substring(with: sync.range(at: 1))) else { continue }
            let contentStart = sync.range.location + sync.range.length
            var contentEnd = index + 1 < syncs.count ? syncs[index + 1].range.location : source.length
            let tail = source.range(of: "</body", options: .caseInsensitive,
                                    range: NSRange(location: contentStart, length: contentEnd - contentStart))
            if tail.location != NSNotFound { contentEnd = tail.location }
            var content = source.substring(with: NSRange(location: contentStart, length: contentEnd - contentStart))
            content = paragraph(in: content, chosenClass: &chosenClass)
            let (body, removed) = clean(content)
            dropped = dropped || removed
            entries.append((max(0, start), body))
        }
        return SubtitleConverter.Parsed(
            cues: SubtitleConverter.closeOpenEnds(entries), notes: dropped ? [.subtitleStylingRemoved] : []
        )
    }

    /// The text of the first language's <P> inside one SYNC, or the whole content when there is no <P>.
    private static func paragraph(in content: String, chosenClass: inout String?) -> String {
        let source = content as NSString
        let paragraphs = paragraphPattern.matches(in: content, range: NSRange(location: 0, length: source.length))
        guard !paragraphs.isEmpty else { return content }
        for (index, paragraph) in paragraphs.enumerated() {
            let attributes = source.substring(with: paragraph.range(at: 1))
            let className = classPattern.firstMatch(in: attributes, range: NSRange(location: 0, length: (attributes as NSString).length))
                .map { (attributes as NSString).substring(with: $0.range(at: 1)).lowercased() } ?? ""
            if chosenClass == nil { chosenClass = className }
            guard className == chosenClass else { continue }
            let start = paragraph.range.location + paragraph.range.length
            let end = index + 1 < paragraphs.count ? paragraphs[index + 1].range.location : source.length
            return source.substring(with: NSRange(location: start, length: end - start))
        }
        return ""
    }

    /// HTML-ish text to cue text: collapses whitespace, `<br>` to newline, keeps <b><i><u>, decodes entities.
    private static func clean(_ html: String) -> (String?, Bool) {
        var text = html.replacingOccurrences(of: #"<!--.*?-->"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</p\s*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        let (stripped, removed) = SubtitleConverter.stripUnsupportedTags(text)
        let decoded = decodeEntities(stripped)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (SubtitleConverter.plainText(decoded).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : SubtitleConverter.canonical(decoded), removed)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        while index < text.endIndex {
            if text[index] == "&", let semicolon = text[index...].prefix(10).firstIndex(of: ";") {
                let name = text[text.index(after: index)..<semicolon].lowercased()
                var replacement: String?
                if let value = named[name] {
                    replacement = value
                } else if name.hasPrefix("#x"), let code = UInt32(name.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                    replacement = String(Character(scalar))
                } else if name.hasPrefix("#"), let code = UInt32(name.dropFirst()), let scalar = Unicode.Scalar(code) {
                    replacement = String(Character(scalar))
                }
                if let replacement {
                    result += replacement
                    index = text.index(after: semicolon)
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    static func render(_ cues: [Cue]) -> String {
        var lines = [
            "<SAMI>",
            "<HEAD>",
            "<TITLE>Subtitles</TITLE>",
            "<STYLE TYPE=\"text/css\">",
            "<!--",
            "P { margin-left: 8pt; margin-right: 8pt; margin-bottom: 2pt; margin-top: 2pt; text-align: center;"
                + " font-size: 20pt; font-family: Arial, sans-serif; font-weight: normal; color: white; }",
            ".SUBTTL { Name: Subtitles; lang: und; SAMIType: CC; }",
            "-->",
            "</STYLE>",
            "</HEAD>",
            "<BODY>",
        ]
        for (index, cue) in cues.enumerated() {
            let text = SubtitleConverter.markup(SubtitleConverter.runs(cue.text), escape: true)
                .replacingOccurrences(of: "\n", with: "<br>")
            lines.append("<SYNC Start=\(cue.start)><P Class=SUBTTL>\(text)")
            let next = index + 1 < cues.count ? cues[index + 1].start : nil
            if next.map({ cue.end < $0 }) ?? true {
                lines.append("<SYNC Start=\(cue.end)><P Class=SUBTTL>&nbsp;")
            }
        }
        lines += ["</BODY>", "</SAMI>"]
        return lines.joined(separator: "\n") + "\n"
    }
}
