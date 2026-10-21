import Foundation

/// Content-based detection for text subtitle formats, and what converting between them may lose.
extension FileFormat {
    /// Subtitle formats with an unmistakable opening: ASS/SSA, TTML/DFXP and SAMI.
    /// Called from `sniff`, so the extension plays no part.
    static func sniffSubtitleSignature(_ bytes: [UInt8]) -> FileFormat? {
        let text = leadingText(bytes)
        if text.hasPrefix("[script info]") {
            if text.contains("scripttype: v4.00+") || text.contains("[v4+ styles]") { return .ass }
            if text.contains("scripttype: v4.00") || text.contains("[v4 styles]") { return .ssa }
            return nil // ASS or SSA: the extension decides in `sniffSubtitleText`
        }
        if text.hasPrefix("<sami") { return .sami }
        if text.hasPrefix("<") && matches(text, #"^(<\?xml[^>]*\?>\s*)?(<!--.*?-->\s*)*<([a-z0-9_]+:)?tt[\s>]"#) {
            return .ttml
        }
        return nil
    }

    /// Subtitle formats recognised by their first line: SBV, MicroDVD and LRC. These patterns are
    /// weaker, so they only apply when the extension is a subtitle one or missing.
    static func sniffSubtitleText(_ bytes: [UInt8], extension byExtension: FileFormat?) -> FileFormat? {
        guard byExtension == nil || byExtension?.family == .subtitle else { return nil }
        let text = leadingText(bytes)
        if text.hasPrefix("[script info]") { return byExtension == .ssa ? .ssa : .ass }
        guard let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) else {
            return nil
        }
        if matches(firstLine, #"^\d+:\d{2}:\d{2}\.\d{3},\d+:\d{2}:\d{2}\.\d{3}\s*$"#) { return .sbv }
        if matches(firstLine, #"^\{\d+\}\{\d*\}"#) { return .microDVD }
        let lrcTag = #"^\[(\d+:\d{1,2}([.:]\d{1,3})?|(ar|ti|al|au|by|offset|length|re|ve|la|id|#|tool|lr|kana):[^\]]*)\]"#
        if matches(firstLine, lrcTag) { return .lrc }
        return nil
    }

    /// The first bytes as lowercased text, without a BOM or leading whitespace, with LF line endings.
    private static func leadingText(_ bytes: [UInt8]) -> String {
        var body = bytes
        if body.starts(with: [0xEF, 0xBB, 0xBF]) { body.removeFirst(3) }
        let decoded: String
        if body.starts(with: [0xFF, 0xFE]) {
            decoded = String(data: Data(body.dropFirst(2)), encoding: .utf16LittleEndian) ?? ""
        } else if body.starts(with: [0xFE, 0xFF]) {
            decoded = String(data: Data(body.dropFirst(2)), encoding: .utf16BigEndian) ?? ""
        } else {
            guard !body.contains(0) else { return "" }
            decoded = String(decoding: body, as: UTF8.self)
        }
        return decoded.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Subtitle formats that can carry positions, colours or fonts beyond bold, italic and underline.
    static let richSubtitleFormats: Set<FileFormat> = [.vtt, .ass, .ssa, .ttml, .sami]
    /// Subtitle formats that can't carry any styling at all.
    static let plainSubtitleFormats: Set<FileFormat> = [.sbv, .lrc]

    /// What converting one subtitle format to another may lose.
    static func subtitleLosses(from source: FileFormat, to target: FileFormat) -> [ConversionNote] {
        var notes: [ConversionNote] = []
        if richSubtitleFormats.contains(source) && !(source == .ass && target == .ssa) && !(source == .ssa && target == .ass)
            || plainSubtitleFormats.contains(target) && !plainSubtitleFormats.contains(source) {
            notes.append(.subtitleStylingRemoved)
        }
        if target == .lrc { notes.append(.subtitleEndTimesDropped) }
        if source == .microDVD || target == .microDVD { notes.append(.subtitleFrameRateAssumed) }
        return notes
    }
}
