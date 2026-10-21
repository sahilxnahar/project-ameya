import AmeyaCore
import Foundation

/// Converts between text subtitle formats. Every format is read into `Cue`s whose text is plain
/// text with `\n` line breaks and only <b>, <i> and <u> tags, then written out again.
/// Format-specific readers and writers live in `SubtitleFormats/`.
enum SubtitleConverter {
    struct Cue: Equatable {
        var start: Int // milliseconds
        var end: Int
        var text: String
    }

    /// What a reader found: the cues and anything the user should be told about.
    struct Parsed {
        var cues: [Cue]
        var notes: [ConversionNote] = []
    }

    static let defaultFrameRate = 23.976

    static func convert(
        _ data: Data, from source: FileFormat, to target: FileFormat, options: ConversionOptions = ConversionOptions()
    ) throws -> (Data, [ConversionNote]) {
        let text = DocumentConverter.decodeText(data).replacingOccurrences(of: "\u{FEFF}", with: "")
        var parsed: Parsed
        switch source {
        case .srt, .vtt:
            let (cues, dropped) = parse(text)
            parsed = Parsed(cues: cues, notes: dropped ? [.subtitleStylingRemoved] : [])
        case .ass, .ssa: parsed = ASSFormat.parse(text)
        case .sbv: parsed = SBVFormat.parse(text)
        case .ttml: parsed = TTMLFormat.parse(data)
        case .lrc: parsed = LRCFormat.parse(text)
        case .microDVD: parsed = MicroDVDFormat.parse(text, frameRate: options.subtitleFrameRate)
        case .sami: parsed = SAMIFormat.parse(text)
        default: throw ConversionError.unsupportedConversion(from: source, to: target)
        }
        var cues = shift(parsed.cues, by: options.subtitleShiftMilliseconds ?? 0)
        cues.sort { $0.start < $1.start }
        guard !cues.isEmpty else { throw ConversionError.noSubtitles }

        var notes = parsed.notes
        let output: String
        switch target {
        case .srt: output = renderSRT(cues)
        case .vtt: output = renderVTT(cues)
        case .ass, .ssa: output = ASSFormat.render(cues, ssa: target == .ssa)
        case .sbv:
            output = SBVFormat.render(cues)
            if cues.contains(where: { hasStyling($0.text) }) { notes.append(.subtitleStylingRemoved) }
        case .ttml: output = TTMLFormat.render(cues)
        case .lrc:
            output = LRCFormat.render(cues)
            if cues.contains(where: { hasStyling($0.text) }) { notes.append(.subtitleStylingRemoved) }
            notes.append(.subtitleEndTimesDropped)
        case .microDVD:
            let (rendered, droppedStyling) = MicroDVDFormat.render(cues, frameRate: options.subtitleFrameRate ?? defaultFrameRate)
            output = rendered
            if droppedStyling { notes.append(.subtitleStylingRemoved) }
            notes.append(.subtitleFrameRateAssumed)
        case .sami: output = SAMIFormat.render(cues)
        default: throw ConversionError.unsupportedTarget(target)
        }
        var unique: [ConversionNote] = []
        for note in notes where !unique.contains(note) { unique.append(note) }
        return (Data(output.utf8), unique)
    }

    /// Moves every cue by `offset` ms, dropping cues that end up entirely before zero.
    static func shift(_ cues: [Cue], by offset: Int) -> [Cue] {
        guard offset != 0 else { return cues }
        return cues.compactMap { cue in
            let end = cue.end + offset
            guard end > 0 else { return nil }
            return Cue(start: max(0, cue.start + offset), end: end, text: cue.text)
        }
    }

    // MARK: SRT and WebVTT

    /// Parses SRT or WebVTT. Returns the cues and whether any styling or positioning was dropped.
    static func parse(_ text: String) -> ([Cue], Bool) {
        let normalised = normaliseLineEndings(text)
        var cues: [Cue] = []
        var dropped = false
        for block in normalised.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            let endText = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            guard parts.count == 2,
                  let start = parseTime(parts[0].trimmingCharacters(in: .whitespaces)),
                  let endField = endText.split(separator: " ").first,
                  let end = parseTime(String(endField)) else { continue }
            if endText.contains(" ") { dropped = true } // WebVTT cue settings
            let body = lines[(timingIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
            let (clean, removedTags) = stripUnsupportedTags(body)
            dropped = dropped || removedTags
            guard !clean.isEmpty else { continue }
            cues.append(Cue(start: start, end: max(end, start), text: clean))
        }
        return (cues, dropped)
    }

    /// Accepts `HH:MM:SS,mmm`, `HH:MM:SS.mmm` and WebVTT's short `MM:SS.mmm`.
    /// Two fraction digits are read as hundredths (ASS), one as tenths.
    static func parseTime(_ value: String) -> Int? {
        let fields = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard fields.count == 2 || fields.count == 3 else { return nil }
        let secondsParts = fields[fields.count - 1].split(separator: ".")
        guard let first = secondsParts.first, let seconds = Int(first), seconds < 60 else { return nil }
        var millis = 0
        if secondsParts.count > 1 {
            let digits = String(secondsParts[1].prefix(3))
            millis = (Int(digits) ?? 0) * [100, 10, 1][max(0, digits.count - 1)]
        }
        guard let minutes = Int(fields[fields.count - 2]), minutes < 60 else { return nil }
        guard let hours = fields.count == 3 ? Int(fields[0]) : 0 else { return nil }
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis
    }

    static func format(_ milliseconds: Int, separator: Character) -> String {
        let totalSeconds = milliseconds / 1000
        return String(format: "%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60)
            + String(separator) + String(format: "%03d", milliseconds % 1000)
    }

    static func renderSRT(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(format(cue.start, separator: ",")) --> \(format(cue.end, separator: ","))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    static func renderVTT(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(format(cue.start, separator: ".")) --> \(format(cue.end, separator: "."))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    /// Keeps <b>, <i>, <u> (understood by both formats) and removes every other tag.
    static func stripUnsupportedTags(_ text: String) -> (String, Bool) {
        var removed = false
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "<", let close = text[index...].firstIndex(of: ">") {
                let name = text[text.index(after: index)..<close].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                if ["b", "i", "u"].contains(name) {
                    result += text[index...close]
                } else {
                    removed = true
                }
                index = text.index(after: close)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return (result.trimmingCharacters(in: .whitespacesAndNewlines), removed)
    }

    // MARK: Shared helpers

    static func normaliseLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// A stretch of cue text with one style.
    struct Run: Equatable {
        var text: String
        var italic = false
        var bold = false
        var underline = false

        var hasStyle: Bool { italic || bold || underline }
        func sameStyle(as other: Run) -> Bool {
            italic == other.italic && bold == other.bold && underline == other.underline
        }
    }

    /// Splits cue text into styled runs. Unbalanced tags are tolerated.
    static func runs(_ text: String) -> [Run] {
        var result: [Run] = []
        var current = Run(text: "")
        var index = text.startIndex
        func flush() {
            guard !current.text.isEmpty else { return }
            if let last = result.last, last.sameStyle(as: current) {
                result[result.count - 1].text += current.text
            } else {
                result.append(current)
            }
            current.text = ""
        }
        while index < text.endIndex {
            if text[index] == "<", let close = text[index...].firstIndex(of: ">") {
                let tag = text[text.index(after: index)..<close].lowercased().replacingOccurrences(of: " ", with: "")
                let closing = tag.hasPrefix("/")
                let name = closing ? String(tag.dropFirst()) : tag
                if ["i", "b", "u"].contains(name) {
                    flush()
                    switch name {
                    case "i": current.italic = !closing
                    case "b": current.bold = !closing
                    default: current.underline = !closing
                    }
                    index = text.index(after: close)
                    continue
                }
            }
            current.text.append(text[index])
            index = text.index(after: index)
        }
        flush()
        return result
    }

    /// Writes runs back as properly nested <b><i><u> markup, escaping text for HTML/XML when asked.
    static func markup(_ runs: [Run], escape: Bool = false) -> String {
        runs.map { run in
            var text = escape ? escapeXML(run.text) : run.text
            if run.underline { text = "<u>\(text)</u>" }
            if run.italic { text = "<i>\(text)</i>" }
            if run.bold { text = "<b>\(text)</b>" }
            return text
        }.joined()
    }

    /// One canonical spelling of styled text: `<i>a</i>\n<i>b</i>` becomes `<i>a\nb</i>`,
    /// so formats that style line by line compare equal to those that style whole cues.
    static func canonical(_ text: String) -> String {
        var pieces = runs(text)
        for index in pieces.indices where index > 0 && index < pieces.count - 1
            && pieces[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pieces[index - 1].sameStyle(as: pieces[index + 1]) {
            let text = pieces[index].text
            pieces[index] = pieces[index - 1]
            pieces[index].text = text
        }
        var merged: [Run] = []
        for piece in pieces {
            if let last = merged.last, last.sameStyle(as: piece) {
                merged[merged.count - 1].text += piece.text
            } else {
                merged.append(piece)
            }
        }
        return markup(merged)
    }

    static func plainText(_ text: String) -> String {
        runs(text).map(\.text).joined()
    }

    static func hasStyling(_ text: String) -> Bool {
        runs(text).contains(where: \.hasStyle)
    }

    static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Gives cues with no end (LRC, SAMI, open MicroDVD lines) the next cue's start, or 4 s for the last.
    static func closeOpenEnds(_ entries: [(start: Int, text: String?)]) -> [Cue] {
        let sorted = entries.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        var cues: [Cue] = []
        for (index, entry) in sorted.enumerated() {
            guard let text = entry.text, !text.isEmpty else { continue }
            let next = sorted[(index + 1)...].first { $0.start > entry.start }?.start
            cues.append(Cue(start: entry.start, end: next ?? entry.start + 4_000, text: text))
        }
        return cues
    }
}
