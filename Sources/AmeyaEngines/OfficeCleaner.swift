import AmeyaCore
import Foundation

/// Removes hidden details from Word, Excel and PowerPoint files by rewriting the ZIP package:
/// author and company properties are emptied, custom properties, the preview picture, printer
/// settings and (in Word) comments, the people list and editing-session IDs are taken out, and
/// every reference to a removed part goes with it so the document still opens cleanly.
enum OfficeCleaner {
    static let emptyCore = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
    xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
    xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"/>
    """
    static let emptyApp = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" \
    xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"/>
    """

    static func clean(_ input: URL, output: URL) throws -> [ConversionNote] {
        let entries = try ArchiveEntries.read(input, limits: ArchiveEntries.Limits(maxEntries: 20_000, maxTotalBytes: 1 << 30))
        guard let package = OfficePrivacy.packageKind(entries), [.word, .excel, .powerPoint].contains(package) else {
            throw ConversionError.refused("Ameya can only remove hidden details from Word, Excel and PowerPoint files.")
        }
        let isWord = package == .word
        let dropped = Set(entries.paths.filter { shouldDrop($0, isWord: isWord) })
        var notes: [ConversionNote] = [.hiddenDetailsRemoved]

        // A fixed, old timestamp: the ZIP's own dates shouldn't say when it was cleaned.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let epoch = calendar.date(from: DateComponents(year: 1980, month: 1, day: 1)) ?? Date(timeIntervalSince1970: 315_532_800)
        var writer = try ZipWriter(url: output, modified: epoch)
        for path in entries.paths where !dropped.contains(path) {
            guard var data = entries[path] else { continue }
            let lower = path.lowercased()
            if lower == "docprops/core.xml" {
                data = Data(emptyCore.utf8)
            } else if lower == "docprops/app.xml" {
                data = Data(emptyApp.utf8)
            } else if lower.hasSuffix(".rels") {
                data = rewriteRelationships(data, at: path, dropping: dropped)
            } else if lower == "[content_types].xml" {
                data = rewriteContentTypes(data, dropping: dropped)
            } else if isWord, lower.hasPrefix("word/"), lower.hasSuffix(".xml") {
                data = cleanWordPart(data, isSettings: lower == "word/settings.xml")
            }
            try writer.add(path, data)
        }
        try writer.finish()

        let all = entries.paths.map { $0.lowercased() }
        if isWord, let document = entries["word/document.xml"],
           XMLTags.count(document, "w:ins") + XMLTags.count(document, "w:del") > 0 {
            notes.append(.trackedChangesKept)
        }
        if !isWord, all.contains(where: { $0.contains("comment") }) { notes.append(.commentsKept) }
        return notes
    }

    /// Parts removed outright.
    static func shouldDrop(_ path: String, isWord: Bool) -> Bool {
        let lower = path.lowercased()
        if lower == "docprops/custom.xml" || lower.hasPrefix("docprops/thumbnail") || lower.contains("printersettings") {
            return true
        }
        guard isWord, lower.hasPrefix("word/") else { return false }
        let name = String(lower.dropFirst(5))
        return name == "people.xml" || (name.hasPrefix("comments") && name.hasSuffix(".xml") && !name.contains("/"))
    }

    /// Removes `<Relationship …/>` entries that point at a dropped part.
    static func rewriteRelationships(_ data: Data, at path: String, dropping dropped: Set<String>) -> Data {
        guard var text = String(data: data, encoding: .utf8) else { return data }
        // "word/_rels/document.xml.rels" describes "word/document.xml"; targets are relative to "word/".
        let owner = (path as NSString).deletingLastPathComponent // word/_rels
        let base = (owner as NSString).deletingLastPathComponent // word
        let droppedLower = Set(dropped.map { $0.lowercased() })
        for match in text.matches(of: #/<Relationship\b[^>]*?/>/#).reversed() {
            let element = String(text[match.range])
            guard !element.contains(#"TargetMode="External""#),
                  let target = element.firstMatch(of: #/Target="([^"]*)"/#)?.output.1 else { continue }
            if droppedLower.contains(resolve(String(target), base: base).lowercased()) {
                text.removeSubrange(match.range)
            }
        }
        return Data(text.utf8)
    }

    static func resolve(_ target: String, base: String) -> String {
        let joined = target.hasPrefix("/") ? String(target.dropFirst()) : (base.isEmpty ? target : "\(base)/\(target)")
        var parts: [String] = []
        for part in joined.split(separator: "/") {
            if part == ".." { _ = parts.popLast() } else if part != "." { parts.append(String(part)) }
        }
        return parts.joined(separator: "/")
    }

    /// Removes `<Override PartName="/…"/>` entries for dropped parts.
    static func rewriteContentTypes(_ data: Data, dropping dropped: Set<String>) -> Data {
        guard var text = String(data: data, encoding: .utf8) else { return data }
        let droppedLower = Set(dropped.map { $0.lowercased() })
        for match in text.matches(of: #/<Override\b[^>]*?/>/#).reversed() {
            let element = String(text[match.range])
            if let part = element.firstMatch(of: #/PartName="/?([^"]*)"/#)?.output.1,
               droppedLower.contains(String(part).lowercased()) {
                text.removeSubrange(match.range)
            }
        }
        return Data(text.utf8)
    }

    /// Comment markers and editing-session IDs (rsid) out of a Word part.
    static func cleanWordPart(_ data: Data, isSettings: Bool) -> Data {
        guard var text = String(data: data, encoding: .utf8) else { return data }
        text = text.replacing(#/<w:comment(RangeStart|RangeEnd|Reference)\b[^>]*?/>/#, with: "")
        text = text.replacing(#/\s+w:rsid[A-Za-z]*="[^"]*"/#, with: "")
        if isSettings {
            text = text.replacing(#/<w:rsids>.*?</w:rsids>/#.dotMatchesNewlines(), with: "")
            text = text.replacing(#/<w:rsids\s*/>/#, with: "")
        }
        return Data(text.utf8)
    }
}
