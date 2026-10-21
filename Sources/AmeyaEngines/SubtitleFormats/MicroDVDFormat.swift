import AmeyaCore
import Foundation

/// MicroDVD (.sub, text): `{startFrame}{endFrame}line|line`. Times are video frames, so a frame rate
/// is needed: the `{1}{1}23.976` first line when present, else 23.976. `{y:i}` (one line) and
/// `{Y:i}` (whole subtitle) carry italic, bold and underline; colours, fonts and positions are dropped.
enum MicroDVDFormat {
    typealias Cue = SubtitleConverter.Cue
    typealias Run = SubtitleConverter.Run

    private static let linePattern = try! NSRegularExpression(pattern: #"^\{(\d+)\}\{(\d*)\}(.*)$"#)

    static func parse(_ text: String, frameRate: Double?) -> SubtitleConverter.Parsed {
        var headerRate: Double?
        var entries: [(start: Int, end: Int?, text: String)] = []
        var dropped = false
        for rawLine in SubtitleConverter.normaliseLineEndings(text).split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = linePattern.firstMatch(in: line, range: range),
                  let startRange = Range(match.range(at: 1), in: line),
                  let endRange = Range(match.range(at: 2), in: line),
                  let bodyRange = Range(match.range(at: 3), in: line),
                  let start = Int(line[startRange]) else { continue }
            let end = Int(line[endRange])
            let body = String(line[bodyRange])
            if entries.isEmpty, headerRate == nil, start <= 1, (end ?? 0) <= 1,
               let rate = Double(body.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")), rate > 0 {
                headerRate = rate
                continue
            }
            let (converted, removed) = convertText(body)
            dropped = dropped || removed
            entries.append((start, end, converted))
        }
        let rate = frameRate ?? headerRate ?? SubtitleConverter.defaultFrameRate
        func milliseconds(_ frame: Int) -> Int { Int((Double(frame) * 1000 / rate).rounded()) }

        var cues: [Cue] = []
        let sorted = entries.sorted { $0.start < $1.start }
        for (index, entry) in sorted.enumerated() where !entry.text.isEmpty {
            let start = milliseconds(entry.start)
            let end: Int
            if let frame = entry.end {
                end = milliseconds(frame)
            } else {
                end = sorted[(index + 1)...].first { $0.start > entry.start }.map { milliseconds($0.start) } ?? start + 4_000
            }
            cues.append(Cue(start: start, end: max(start, end), text: entry.text))
        }
        var notes: [ConversionNote] = dropped ? [.subtitleStylingRemoved] : []
        if frameRate == nil && headerRate == nil { notes.append(.subtitleFrameRateAssumed) }
        return SubtitleConverter.Parsed(cues: cues, notes: notes)
    }

    /// Converts `{Y:i}line|{y:b}line` to cue text. Returns whether any control codes were dropped.
    static func convertText(_ body: String) -> (String, Bool) {
        var dropped = false
        var whole = Run(text: "")
        var lines: [String] = []
        for (index, rawLine) in body.split(separator: "|", omittingEmptySubsequences: false).enumerated() {
            var line = Substring(rawLine)
            var style = whole
            while line.hasPrefix("{"), let close = line.firstIndex(of: "}"),
                  let colon = line[..<close].firstIndex(of: ":") {
                let code = line[line.index(after: line.startIndex)..<colon]
                let value = line[line.index(after: colon)..<close].lowercased()
                if code == "y" || code == "Y" {
                    var target = Run(text: "")
                    target.italic = value.contains("i")
                    target.bold = value.contains("b")
                    target.underline = value.contains("u")
                    if code == "Y" && index == 0 { whole = target }
                    style.italic = style.italic || target.italic
                    style.bold = style.bold || target.bold
                    style.underline = style.underline || target.underline
                } else {
                    dropped = true
                }
                line = line[line.index(after: close)...]
            }
            style.text = line.trimmingCharacters(in: .whitespaces)
            lines.append(SubtitleConverter.markup([style]))
        }
        return (SubtitleConverter.canonical(lines.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines), dropped)
    }

    /// Returns the file and whether styling that MicroDVD can't express (part of a line) was dropped.
    static func render(_ cues: [Cue], frameRate: Double) -> (String, Bool) {
        var dropped = false
        var output = ["{1}{1}\(formatRate(frameRate))"]
        func frame(_ milliseconds: Int) -> Int { Int((Double(milliseconds) * frameRate / 1000).rounded()) }
        for cue in cues {
            var lines: [String] = []
            for lineRuns in splitLines(SubtitleConverter.runs(cue.text)) {
                let visible = lineRuns.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                var codes = ""
                if !visible.isEmpty {
                    if visible.allSatisfy(\.bold) { codes += "b" }
                    if visible.allSatisfy(\.italic) { codes += "i" }
                    if visible.allSatisfy(\.underline) { codes += "u" }
                    let partial = visible.contains(where: \.bold) && !codes.contains("b")
                        || visible.contains(where: \.italic) && !codes.contains("i")
                        || visible.contains(where: \.underline) && !codes.contains("u")
                    dropped = dropped || partial
                }
                let prefix = codes.isEmpty ? "" : "{y:\(codes.map(String.init).joined(separator: ","))}"
                lines.append(prefix + lineRuns.map(\.text).joined().trimmingCharacters(in: .whitespaces))
            }
            output.append("{\(frame(cue.start))}{\(frame(cue.end))}\(lines.joined(separator: "|"))")
        }
        return (output.joined(separator: "\n") + "\n", dropped)
    }

    private static func splitLines(_ runs: [Run]) -> [[Run]] {
        var lines: [[Run]] = [[]]
        for run in runs {
            for (index, piece) in run.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if index > 0 { lines.append([]) }
                var copy = run
                copy.text = String(piece)
                if !piece.isEmpty { lines[lines.count - 1].append(copy) }
            }
        }
        return lines
    }

    static func formatRate(_ rate: Double) -> String {
        var text = String(format: "%.3f", rate)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
