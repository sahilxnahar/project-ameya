import AmeyaCore
import Foundation

/// SRT ↔ WebVTT. Timings and text are kept exactly; WebVTT positioning and styling
/// (which SRT can't express) are dropped, apart from <b>, <i> and <u>.
enum SubtitleConverter {
    struct Cue: Equatable {
        var start: Int // milliseconds
        var end: Int
        var text: String
    }

    static func convert(_ data: Data, from source: FileFormat, to target: FileFormat) throws -> (Data, [ConversionNote]) {
        let text = DocumentConverter.decodeText(data)
        let (cues, droppedStyling) = parse(text)
        guard !cues.isEmpty else { throw ConversionError.noSubtitles }
        let output: String = switch target {
        case .srt: renderSRT(cues)
        case .vtt: renderVTT(cues)
        default: throw ConversionError.unsupportedTarget(target)
        }
        return (Data(output.utf8), droppedStyling && target == .srt ? [.subtitleStylingRemoved] : [])
    }

    /// Parses SRT or WebVTT. Returns the cues and whether any styling or positioning was dropped.
    static func parse(_ text: String) -> ([Cue], Bool) {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
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
}
