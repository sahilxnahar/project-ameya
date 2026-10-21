import AmeyaCore
import Foundation

/// LRC synced lyrics: `[mm:ss.xx]line`. A line may carry several timestamps; `[offset:+/-ms]`
/// moves every line (positive = earlier). Lines only have start times, so each cue ends when the
/// next line starts (the last one after 4 s). Lines sharing a timestamp become one multi-line cue.
enum LRCFormat {
    typealias Cue = SubtitleConverter.Cue

    static func parse(_ text: String) -> SubtitleConverter.Parsed {
        var entries: [(start: Int, text: String)] = []
        var offset = 0
        for rawLine in SubtitleConverter.normaliseLineEndings(text).split(separator: "\n") {
            var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var times: [Int] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = parseTime(tag) {
                    times.append(time)
                } else if tag.lowercased().hasPrefix("offset:"),
                          let value = Int(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)
                              .replacingOccurrences(of: "+", with: "")) {
                    offset = value
                }
                rest = rest[rest.index(after: close)...]
            }
            let lyric = stripWordTimes(String(rest)).trimmingCharacters(in: .whitespaces)
            for time in times { entries.append((time, lyric)) }
        }
        // Merge lines that share a timestamp, keeping blank lines as "clear" markers.
        var merged: [(start: Int, text: String?)] = []
        for entry in entries.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, last.start == entry.start {
                let joined = [last.text ?? "", entry.text].filter { !$0.isEmpty }.joined(separator: "\n")
                merged[merged.count - 1].text = joined
            } else {
                merged.append((entry.start, entry.text))
            }
        }
        let shifted = merged.map { (start: max(0, $0.start - offset), text: $0.text) }
        return SubtitleConverter.Parsed(cues: SubtitleConverter.closeOpenEnds(shifted))
    }

    /// `mm:ss`, `mm:ss.xx`, `mm:ss.xxx`, `mm:ss:xx` or `hh:mm:ss.xx`. Minutes may exceed 59.
    static func parseTime(_ tag: Substring) -> Int? {
        let fields = tag.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 2 || fields.count == 3, fields.allSatisfy({ !$0.isEmpty }) else { return nil }
        var hours = 0, minutesField = fields[0], secondsField = fields[1], fraction = ""
        if fields.count == 3 {
            if fields[2].contains(".") { // hh:mm:ss.xx; otherwise the old mm:ss:xx form
                hours = Int(fields[0]) ?? -1
                minutesField = fields[1]
                secondsField = fields[2]
            } else {
                fraction = fields[2] // mm:ss:xx
            }
        }
        let secondParts = secondsField.split(separator: ".", omittingEmptySubsequences: false)
        if secondParts.count == 2 { fraction = String(secondParts[1]) }
        guard hours >= 0, let minutes = Int(minutesField), let seconds = Int(secondParts[0]), seconds < 60,
              fraction.allSatisfy(\.isNumber), fraction.count <= 3 else { return nil }
        let millis = fraction.isEmpty ? 0 : (Int(fraction) ?? 0) * [100, 10, 1][fraction.count - 1]
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis
    }

    /// Removes enhanced-LRC word timestamps such as `<00:12.34>`.
    static func stripWordTimes(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\d+:\d+(?:[.:]\d+)?>"#, with: "", options: .regularExpression)
    }

    static func render(_ cues: [Cue]) -> String {
        var lines = ["[re:Ameya]"]
        for cue in cues {
            for line in SubtitleConverter.plainText(cue.text).split(separator: "\n") {
                lines.append("[\(time(cue.start))]\(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `mm:ss.xx`; minutes keep counting past 59.
    static func time(_ milliseconds: Int) -> String {
        let centiseconds = (milliseconds + 5) / 10
        let seconds = centiseconds / 100
        return String(format: "%02d:%02d.%02d", seconds / 60, seconds % 60, centiseconds % 100)
    }
}
