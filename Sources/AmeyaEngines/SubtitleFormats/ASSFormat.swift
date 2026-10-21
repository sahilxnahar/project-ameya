import AmeyaCore
import Foundation

/// Advanced SubStation Alpha (.ass) and SubStation Alpha (.ssa).
/// Reads the [Events] section in the order its Format line gives; keeps \i, \b and \u override
/// tags as <i>, <b>, <u>. Positions, colours, fonts, karaoke and animation are dropped.
enum ASSFormat {
    typealias Cue = SubtitleConverter.Cue
    typealias Run = SubtitleConverter.Run

    /// Used when [Events] has no Format line. SSA's `Marked` sits where ASS has `Layer`.
    static let defaultFields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]

    static func parse(_ text: String) -> SubtitleConverter.Parsed {
        var section = ""
        var fields = defaultFields
        var cues: [Cue] = []
        var dropped = false
        for rawLine in SubtitleConverter.normaliseLineEndings(text).split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = line.lowercased()
                continue
            }
            guard section == "[events]", let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
            if key == "format" {
                fields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard key == "dialogue", !fields.isEmpty,
                  let startIndex = fields.firstIndex(of: "start"),
                  let endIndex = fields.firstIndex(of: "end"),
                  let textIndex = fields.firstIndex(of: "text") else { continue }
            // Text is the last field, so commas inside it are kept.
            let parts = value.split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false)
            guard parts.count == fields.count,
                  let start = SubtitleConverter.parseTime(parts[startIndex].trimmingCharacters(in: .whitespaces)),
                  let end = SubtitleConverter.parseTime(parts[endIndex].trimmingCharacters(in: .whitespaces)) else { continue }
            let (body, removed) = convertText(String(parts[textIndex]))
            dropped = dropped || removed
            guard !body.isEmpty else { continue }
            cues.append(Cue(start: start, end: max(start, end), text: body))
        }
        return SubtitleConverter.Parsed(cues: cues, notes: dropped ? [.subtitleStylingRemoved] : [])
    }

    /// Turns ASS dialogue text into cue text. Returns whether any override tags were dropped.
    static func convertText(_ raw: String) -> (String, Bool) {
        var runs: [Run] = []
        var current = Run(text: "")
        var dropped = false
        func flush() {
            guard !current.text.isEmpty else { return }
            runs.append(current)
            current.text = ""
        }
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "{", let close = raw[index...].firstIndex(of: "}") {
                let block = raw[raw.index(after: index)..<close]
                if block.contains("\\") {
                    var style = current
                    for tag in block.split(separator: "\\").map({ $0.trimmingCharacters(in: .whitespaces) }) where !tag.isEmpty {
                        let name = tag.first!
                        let argument = tag.dropFirst()
                        if "ibu".contains(name), !argument.isEmpty, argument.allSatisfy(\.isNumber) {
                            let on = Int(argument) != 0
                            switch name {
                            case "i": style.italic = on
                            case "b": style.bold = on
                            default: style.underline = on
                            }
                        } else if name == "r" {
                            style.italic = false
                            style.bold = false
                            style.underline = false
                        } else {
                            dropped = true
                        }
                    }
                    if !style.sameStyle(as: current) {
                        flush()
                        current.italic = style.italic
                        current.bold = style.bold
                        current.underline = style.underline
                    }
                }
                index = raw.index(after: close)
                continue
            }
            if character == "\\", raw.index(after: index) < raw.endIndex {
                let next = raw[raw.index(after: index)]
                if next == "N" || next == "n" || next == "h" {
                    current.text += next == "N" ? "\n" : " "
                    index = raw.index(index, offsetBy: 2)
                    continue
                }
            }
            current.text.append(character)
            index = raw.index(after: index)
        }
        flush()
        let joined = SubtitleConverter.markup(runs)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (SubtitleConverter.canonical(joined), dropped)
    }

    static func render(_ cues: [Cue], ssa: Bool) -> String {
        var lines = [
            "[Script Info]",
            "; Written by Ameya",
            "Title: Subtitles",
            "ScriptType: \(ssa ? "v4.00" : "v4.00+")",
            "PlayResX: 1920",
            "PlayResY: 1080",
            "WrapStyle: 0",
        ]
        if ssa {
            lines += [
                "",
                "[V4 Styles]",
                "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, "
                    + "BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding",
                "Style: Default,Arial,72,16777215,255,0,0,0,0,1,3,1,2,40,40,50,0,1",
                "",
                "[Events]",
                "Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
            ]
        } else {
            lines += [
                "ScaledBorderAndShadow: yes",
                "",
                "[V4+ Styles]",
                "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, "
                    + "Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, "
                    + "MarginL, MarginR, MarginV, Encoding",
                "Style: Default,Arial,72,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,3,1,2,40,40,50,1",
                "",
                "[Events]",
                "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
            ]
        }
        let first = ssa ? "Marked=0" : "0"
        for cue in cues {
            lines.append("Dialogue: \(first),\(time(cue.start)),\(time(cue.end)),Default,,0,0,0,,\(dialogueText(cue.text))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `H:MM:SS.cc`, rounded to the nearest hundredth.
    static func time(_ milliseconds: Int) -> String {
        let centiseconds = (milliseconds + 5) / 10
        let seconds = centiseconds / 100
        return String(format: "%d:%02d:%02d.%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60, centiseconds % 100)
    }

    static func dialogueText(_ text: String) -> String {
        var state = Run(text: "")
        var output = ""
        for run in SubtitleConverter.runs(text) {
            var tags = ""
            if run.bold != state.bold { tags += "\\b\(run.bold ? 1 : 0)" }
            if run.italic != state.italic { tags += "\\i\(run.italic ? 1 : 0)" }
            if run.underline != state.underline { tags += "\\u\(run.underline ? 1 : 0)" }
            if !tags.isEmpty { output += "{\(tags)}" }
            output += run.text.replacingOccurrences(of: "\n", with: "\\N")
            state = run
        }
        return output
    }
}
