import AmeyaCore
import Foundation

/// W3C Timed Text (TTML 1.0) and its older name DFXP. Reads <p> cues with clock times
/// (`hh:mm:ss.fff`, `hh:mm:ss:ff` using ttp:frameRate) and offsets (`12.5s`, `300ms`, `25f`, `9000t`),
/// relative to timed <body>/<div> parents. Italic, bold and underline (inline or via <style>) are kept;
/// regions, colours and fonts are dropped.
enum TTMLFormat {
    typealias Cue = SubtitleConverter.Cue

    static func parse(_ data: Data) -> SubtitleConverter.Parsed {
        let reader = TTMLReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        _ = parser.parse() // Cues read before any XML error are kept.
        let cues = reader.entries.enumerated().compactMap { index, entry -> Cue? in
            let end = entry.end ?? reader.entries[(index + 1)...].first { $0.begin > entry.begin }?.begin ?? entry.begin + 4_000
            return Cue(start: entry.begin, end: max(entry.begin, end), text: entry.text)
        }
        return SubtitleConverter.Parsed(cues: cues, notes: reader.dropped ? [.subtitleStylingRemoved] : [])
    }

    static func render(_ cues: [Cue]) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<tt xmlns="http://www.w3.org/ns/ttml" xmlns:tts="http://www.w3.org/ns/ttml#styling" "#
                + #"xmlns:ttp="http://www.w3.org/ns/ttml#parameter" ttp:timeBase="media" xml:lang="und">"#,
            "  <body>",
            "    <div>",
        ]
        for cue in cues {
            let content = SubtitleConverter.runs(cue.text).map { run -> String in
                let text = SubtitleConverter.escapeXML(run.text).replacingOccurrences(of: "\n", with: "<br/>")
                var attributes = ""
                if run.italic { attributes += #" tts:fontStyle="italic""# }
                if run.bold { attributes += #" tts:fontWeight="bold""# }
                if run.underline { attributes += #" tts:textDecoration="underline""# }
                return attributes.isEmpty ? text : "<span\(attributes)>\(text)</span>"
            }.joined()
            lines.append(#"      <p begin="\#(time(cue.start))" end="\#(time(cue.end))">\#(content)</p>"#)
        }
        lines += ["    </div>", "  </body>", "</tt>"]
        return lines.joined(separator: "\n") + "\n"
    }

    /// `HH:MM:SS.mmm`
    static func time(_ milliseconds: Int) -> String {
        SubtitleConverter.format(milliseconds, separator: ".")
    }
}

/// Collects <p> cues while XMLParser walks a TTML document.
final class TTMLReader: NSObject, XMLParserDelegate {
    typealias Run = SubtitleConverter.Run

    struct Entry {
        var begin: Int
        var end: Int?
        var text: String
    }

    private struct Element {
        var name: String
        var begin: Int // absolute, ms
        var end: Int? // absolute, ms
        var style: Run
    }

    private(set) var entries: [Entry] = []
    private(set) var dropped = false

    private var frameRate = 30.0
    private var frameRateGiven = false
    private var frameRateMultiplier = 1.0
    private var subFrameRate = 1.0
    private var tickRate: Double?
    private var namedStyles: [String: [String: String]] = [:]
    private var stack: [Element] = []
    private var paragraph: (begin: Int, end: Int?, runs: [Run])?

    private static let lineBreak = "\u{2028}"

    private static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        let name = Self.localName(elementName)
        var local: [String: String] = [:]
        for (key, value) in attributes { local[Self.localName(key)] = value }

        switch name {
        case "tt":
            if let rate = local["frameRate"].flatMap(Double.init), rate > 0 {
                frameRate = rate
                frameRateGiven = true
            }
            if let parts = local["frameRateMultiplier"]?.split(separator: " ").compactMap({ Double($0) }),
               parts.count == 2, parts[1] > 0 {
                frameRateMultiplier = parts[0] / parts[1]
            }
            if let rate = local["subFrameRate"].flatMap(Double.init), rate > 0 { subFrameRate = rate }
            if let rate = local["tickRate"].flatMap(Double.init), rate > 0 { tickRate = rate }
        case "style" where paragraph == nil:
            if let id = local["id"] {
                var properties = local["style"].flatMap { namedStyles[$0] } ?? [:]
                for (key, value) in attributes where key.hasPrefix("tts:") || key.contains(":font") || key.contains(":text") {
                    properties[Self.localName(key)] = value
                }
                namedStyles[id] = properties
            }
            return
        case "br":
            paragraph?.runs.append(Run(text: Self.lineBreak))
            return
        default:
            break
        }

        let parent = stack.last
        let parentBegin = parent?.begin ?? 0
        let begin = parentBegin + (local["begin"].flatMap(parseTime) ?? 0)
        var end = parent?.end
        if let value = local["end"].flatMap(parseTime) {
            end = parentBegin + value
        } else if let duration = local["dur"].flatMap(parseTime) {
            end = begin + duration
        }

        var style = parent?.style ?? Run(text: "")
        for id in (local["style"] ?? "").split(separator: " ") {
            apply(namedStyles[String(id)] ?? [:], to: &style, checkUnsupported: false)
        }
        var inline: [String: String] = [:]
        for (key, value) in attributes where key.hasPrefix("tts:") { inline[Self.localName(key)] = value }
        let isContent = paragraph != nil || name == "p" || name == "span"
        apply(inline, to: &style, checkUnsupported: isContent)
        if isContent && local["region"] != nil { dropped = true }
        stack.append(Element(name: name, begin: begin, end: end, style: style))
        if name == "p" { paragraph = (begin, end, []) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard paragraph != nil, let style = stack.last?.style else { return }
        var run = style
        run.text = string
        paragraph?.runs.append(run)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = Self.localName(elementName)
        guard name != "br", !(name == "style" && paragraph == nil) else { return }
        if !stack.isEmpty { stack.removeLast() }
        guard name == "p", let current = paragraph else { return }
        paragraph = nil
        // XML whitespace collapses to single spaces; <br/> markers become line breaks.
        let collapsed = current.runs.map { run -> Run in
            var copy = run
            copy.text = run.text.replacingOccurrences(of: #"[ \t\r\n]+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: Self.lineBreak, with: "\n")
            return copy
        }
        let text = SubtitleConverter.markup(collapsed)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !SubtitleConverter.plainText(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.append(Entry(begin: current.begin, end: current.end, text: SubtitleConverter.canonical(text)))
    }

    private func apply(_ properties: [String: String], to style: inout Run, checkUnsupported: Bool) {
        for (key, value) in properties {
            switch key {
            case "fontStyle": style.italic = value == "italic" || value == "oblique"
            case "fontWeight": style.bold = value == "bold"
            case "textDecoration":
                if value.contains("noUnderline") { style.underline = false } else if value.contains("underline") { style.underline = true }
            default: if checkUnsupported { dropped = true }
            }
        }
    }

    /// Clock time (`hh:mm:ss`, `hh:mm:ss.fff`, `hh:mm:ss:ff`, `hh:mm:ss:ff.s`) or offset time
    /// (`12.5h|m|s|ms|f|t`), in milliseconds.
    func parseTime(_ raw: String) -> Int? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let effectiveRate = frameRate * frameRateMultiplier
        if let match = value.firstMatch(of: #/^(\d+(?:\.\d+)?)(ms|h|m|s|f|t)$/#), let number = Double(match.1) {
            let seconds: Double = switch match.2 {
            case "h": number * 3600
            case "m": number * 60
            case "s": number
            case "ms": number / 1000
            case "f": number / effectiveRate
            default: number / (tickRate ?? (frameRateGiven ? effectiveRate * subFrameRate : 1))
            }
            return Int((seconds * 1000).rounded())
        }
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3 || fields.count == 4,
              let hours = Int(fields[0]), let minutes = Int(fields[1]), minutes < 60,
              let seconds = Double(fields[2]), seconds < 60 else { return nil }
        var total = Double(hours * 3600 + minutes * 60) + seconds
        if fields.count == 4 {
            let frameParts = fields[3].split(separator: ".")
            guard let frames = frameParts.first.flatMap({ Double($0) }) else { return nil }
            let subFrames = frameParts.count > 1 ? Double(frameParts[1]) ?? 0 : 0
            total += (frames + subFrames / subFrameRate) / effectiveRate
        }
        return Int((total * 1000).rounded())
    }
}
