import AmeyaCore
import Foundation

/// YouTube's SubViewer (.sbv): `0:00:01.000,0:00:02.500` then the text, blocks split by blank lines.
/// SBV has no styling, so tags are removed when writing.
enum SBVFormat {
    typealias Cue = SubtitleConverter.Cue

    static func parse(_ text: String) -> SubtitleConverter.Parsed {
        var cues: [Cue] = []
        var dropped = false
        for block in SubtitleConverter.normaliseLineEndings(text).components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let timing = lines.first else { continue }
            let times = timing.split(separator: ",")
            guard times.count == 2,
                  let start = SubtitleConverter.parseTime(String(times[0])),
                  let end = SubtitleConverter.parseTime(String(times[1])) else { continue }
            let (body, removed) = SubtitleConverter.stripUnsupportedTags(lines.dropFirst().joined(separator: "\n"))
            dropped = dropped || removed
            guard !body.isEmpty else { continue }
            cues.append(Cue(start: start, end: max(start, end), text: body))
        }
        return SubtitleConverter.Parsed(cues: cues, notes: dropped ? [.subtitleStylingRemoved] : [])
    }

    static func render(_ cues: [Cue]) -> String {
        cues.map { cue in
            "\(time(cue.start)),\(time(cue.end))\n\(SubtitleConverter.plainText(cue.text))\n"
        }.joined(separator: "\n")
    }

    /// `H:MM:SS.mmm`
    static func time(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        return String(format: "%d:%02d:%02d.%03d", seconds / 3600, (seconds / 60) % 60, seconds % 60, milliseconds % 1000)
    }
}
