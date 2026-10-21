import AmeyaCore
import Foundation

/// Hidden details in ZIP-based documents: Word, Excel and PowerPoint (Office Open XML),
/// OpenDocument and EPUB. Only the small metadata parts are unpacked, through libarchive.
enum OfficePrivacy {
    typealias Finding = PrivacyReport.Finding

    enum Package: Equatable { case word, excel, powerPoint, openDocument, epub }

    /// Parts worth reading for the privacy check (everything else stays packed).
    static func isMetadataPart(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.hasSuffix(".rels") || lower == "[content_types].xml" { return false }
        return lower.hasPrefix("docprops/") || lower == "meta.xml" || lower == "meta-inf/container.xml"
            || lower.hasSuffix(".opf") || lower.contains("comment") || lower.hasSuffix("people.xml")
            || lower.hasSuffix("persons/person.xml") || lower == "word/document.xml" || lower == "word/settings.xml"
            || lower == "xl/workbook.xml" || lower == "ppt/presentation.xml"
            || (lower.hasPrefix("ppt/slides/slide") && lower.hasSuffix(".xml")) || lower.contains("printersettings")
            || lower.hasPrefix("customxml/") || lower == "mimetype"
    }

    static func read(_ url: URL) throws -> ArchiveEntries {
        try ArchiveEntries.read(url, limits: ArchiveEntries.Limits(maxEntries: 20_000, maxTotalBytes: 300 << 20),
                                include: isMetadataPart)
    }

    static func packageKind(_ url: URL) -> Package? {
        guard let entries = try? ArchiveEntries.read(url, limits: ArchiveEntries.Limits(maxEntries: 20_000, maxTotalBytes: 64 << 20),
                                                     include: { ["mimetype", "meta.xml", "meta-inf/container.xml"].contains($0.lowercased()) })
        else { return nil }
        return packageKind(entries)
    }

    static func packageKind(_ entries: ArchiveEntries) -> Package? {
        let all = Set((entries.paths + entries.excluded).map { $0.lowercased() })
        if all.contains("word/document.xml") { return .word }
        if all.contains("xl/workbook.xml") { return .excel }
        if all.contains("ppt/presentation.xml") { return .powerPoint }
        let mimetype = entries["mimetype"].map { String(decoding: $0, as: UTF8.self) } ?? ""
        if mimetype.hasPrefix("application/epub+zip") || all.contains("meta-inf/container.xml") && all.contains(where: { $0.hasSuffix(".opf") }) {
            return .epub
        }
        if mimetype.hasPrefix("application/vnd.oasis.opendocument") || all.contains("meta.xml") { return .openDocument }
        return nil
    }

    static func inspect(_ url: URL) throws -> PrivacyReport {
        let entries = try read(url)
        guard let package = packageKind(entries) else {
            return PrivacyReport(kind: .other, canClean: false, kept: ["Ameya doesn't know how to look inside this kind of file yet."])
        }
        var found: [Finding] = []
        var kept: [String] = []
        switch package {
        case .epub:
            found = epubFindings(entries)
            kept.append("Ameya can show the details of e-books but can't remove them yet.")
            return PrivacyReport(kind: .epub, findings: found, canClean: false, kept: kept)
        case .openDocument:
            found = leafFindings(entries["meta.xml"])
            kept.append("Ameya can show the details of OpenDocument files but can't remove them yet.")
            return PrivacyReport(kind: .office, findings: found, canClean: false, kept: kept)
        case .word, .excel, .powerPoint:
            found = leafFindings(entries["docProps/core.xml"]) + leafFindings(entries["docProps/app.xml"])
            found += customProperties(entries["docProps/custom.xml"])
            if entries.paths.contains(where: { $0.lowercased().hasPrefix("docprops/thumbnail") })
                || entries.excluded.contains(where: { $0.lowercased().hasPrefix("docprops/thumbnail") }) {
                found.append(Finding(group: .other, label: "Preview picture", value: "A small picture of the first page"))
            }
            let (comments, commentFindings) = self.comments(entries, package: package)
            found += commentFindings
            if package == .word {
                let (tracked, trackedFindings) = trackedChanges(entries)
                found += trackedFindings
                if tracked { kept.append(ConversionNote.trackedChangesKept.message) }
            } else if comments {
                kept.append(ConversionNote.commentsKept.message)
            }
            found += hiddenParts(entries, package: package)
            if (entries.paths + entries.excluded).contains(where: { $0.lowercased().contains("printersettings") }) {
                found.append(Finding(group: .device, label: "Printer settings", value: "Saved from the computer that last printed it"))
            }
            return PrivacyReport(kind: .office, findings: unique(found), canClean: true, kept: kept)
        }
    }

    // MARK: Parts

    /// core.xml, app.xml and meta.xml: one element per detail.
    private static func leafFindings(_ data: Data?) -> [Finding] {
        guard let data else { return [] }
        let labels: [String: (PrivacyReport.Group, String)] = [
            "dc:creator": (.name, "Author"), "cp:lastModifiedBy": (.name, "Last changed by"),
            "meta:initial-creator": (.name, "Author"), "Company": (.name, "Company"), "Manager": (.name, "Manager"),
            "dcterms:created": (.edits, "Created"), "dcterms:modified": (.edits, "Last changed"),
            "meta:creation-date": (.edits, "Created"), "dc:date": (.edits, "Last changed"),
            "cp:lastPrinted": (.edits, "Last printed"), "meta:print-date": (.edits, "Last printed"),
            "cp:revision": (.edits, "Times saved"), "meta:editing-cycles": (.edits, "Times saved"),
            "TotalTime": (.edits, "Minutes spent editing"), "Application": (.edits, "Made with"),
            "AppVersion": (.edits, "App version"), "meta:generator": (.edits, "Made with"),
            "Template": (.other, "Template"), "dc:title": (.other, "Title"), "dc:subject": (.other, "Subject"),
            "cp:keywords": (.other, "Keywords"), "meta:keyword": (.other, "Keywords"), "dc:description": (.other, "Comments field"),
            "cp:category": (.other, "Category"), "HyperlinkBase": (.other, "Link base"),
        ]
        return XMLLeaves.collect(data, limit: 300).compactMap { name, value in
            guard let (group, label) = labels[name], !value.isEmpty, !(name == "TotalTime" && value == "0") else { return nil }
            return Finding(group: group, label: label, value: value)
        }
    }

    private static func customProperties(_ data: Data?) -> [Finding] {
        guard let data else { return [] }
        var found: [Finding] = []
        var current: String?
        for (name, value) in XMLLeaves.collect(data, limit: 400) {
            if name == "name" { current = value } else if name.hasPrefix("vt:"), let property = current {
                found.append(Finding(group: .other, label: "Custom detail “\(PrivacyReport.clip(property, limit: 40))”", value: value))
                current = nil
            }
        }
        return found
    }

    private static func comments(_ entries: ArchiveEntries, package: Package) -> (Bool, [Finding]) {
        var count = 0
        var authors: [String] = []
        func addAuthor(_ name: String) {
            if !name.isEmpty, !authors.contains(name), authors.count < 20 { authors.append(name) }
        }
        for path in entries.paths {
            let lower = path.lowercased()
            guard let data = entries[path] else { continue }
            let pairs = XMLLeaves.collect(data, limit: 5_000)
            if lower == "word/comments.xml" {
                count += XMLTags.count(data, "w:comment")
                pairs.filter { $0.0 == "w:author" }.forEach { addAuthor($0.1) }
            } else if lower.hasSuffix("people.xml") || lower.hasSuffix("persons/person.xml") {
                pairs.filter { ["w15:author", "displayName"].contains($0.0) }.forEach { addAuthor($0.1) }
            } else if lower.hasPrefix("xl/comments") {
                count += XMLTags.count(data, "comment")
                pairs.filter { $0.0 == "author" }.forEach { addAuthor($0.1) }
            } else if lower.hasPrefix("xl/threadedcomments") {
                count += XMLTags.count(data, "threadedComment")
            } else if lower.hasPrefix("ppt/comments/") {
                count += XMLTags.count(data, "p:cm") + XMLTags.count(data, "p188:cm")
            } else if lower == "ppt/commentauthors.xml" || lower.hasPrefix("ppt/authors") {
                pairs.filter { $0.0 == "name" }.forEach { addAuthor($0.1) }
            }
        }
        var found: [Finding] = []
        if count > 0 { found.append(Finding(group: .other, label: "Comments", value: "\(count) comment\(count == 1 ? "" : "s")")) }
        if !authors.isEmpty { found.append(Finding(group: .name, label: "Comment authors", value: authors.joined(separator: ", "))) }
        return (count > 0, found)
    }

    private static func trackedChanges(_ entries: ArchiveEntries) -> (Bool, [Finding]) {
        var found: [Finding] = []
        var tracked = false
        if let document = entries["word/document.xml"] {
            let changes = XMLTags.count(document, "w:ins") + XMLTags.count(document, "w:del")
            if changes > 0 {
                tracked = true
                found.append(Finding(group: .edits, label: "Tracked changes", value: "\(changes) change\(changes == 1 ? "" : "s") still saved"))
                let authors = Array(Set(XMLLeaves.collect(document, limit: 20_000).filter { $0.0 == "w:author" }.map(\.1))).sorted()
                if !authors.isEmpty {
                    found.append(Finding(group: .name, label: "People who made changes", value: authors.prefix(20).joined(separator: ", ")))
                }
            }
        }
        if let settings = entries["word/settings.xml"] {
            let sessions = XMLTags.count(settings, "w:rsid")
            if sessions > 0 {
                found.append(Finding(group: .edits, label: "Editing-session IDs", value: "\(sessions) (can show which documents share a history)"))
            }
        }
        return (tracked, found)
    }

    private static func hiddenParts(_ entries: ArchiveEntries, package: Package) -> [Finding] {
        var found: [Finding] = []
        if package == .excel, let workbook = entries["xl/workbook.xml"] {
            let hidden = XMLTags.attributes(workbook, "sheet").filter { ["hidden", "veryHidden"].contains($0["state"] ?? "") }
            if !hidden.isEmpty {
                found.append(Finding(group: .other, label: "Hidden sheets", value: hidden.compactMap { $0["name"] }.prefix(20).joined(separator: ", ")))
            }
        }
        if package == .powerPoint {
            let hidden = entries.paths.filter { path in
                path.lowercased().hasPrefix("ppt/slides/slide") && (entries[path].map { XMLTags.attributes($0, "p:sld").first?["show"] == "0" } ?? false)
            }
            if !hidden.isEmpty { found.append(Finding(group: .other, label: "Hidden slides", value: "\(hidden.count)")) }
        }
        if (entries.paths + entries.excluded).contains(where: { $0.lowercased().hasPrefix("customxml/item") }) {
            found.append(Finding(group: .other, label: "Custom data", value: "Extra data added by other apps"))
        }
        return found
    }

    private static func epubFindings(_ entries: ArchiveEntries) -> [Finding] {
        guard let opf = entries.paths.first(where: { $0.lowercased().hasSuffix(".opf") }), let data = entries[opf] else { return [] }
        let labels: [String: (PrivacyReport.Group, String)] = [
            "dc:creator": (.name, "Author"), "dc:contributor": (.name, "Contributor"), "dc:publisher": (.name, "Publisher"),
            "dc:rights": (.name, "Rights"), "dc:date": (.edits, "Date"), "dc:identifier": (.other, "Book ID"),
            "dc:title": (.other, "Title"), "dc:description": (.other, "Description"),
        ]
        var found: [Finding] = XMLLeaves.collect(data, limit: 500).compactMap { name, value in
            labels[name].map { Finding(group: $0.0, label: $0.1, value: value) }
        }
        for attributes in XMLTags.attributes(data, "meta") {
            if attributes["name"] == "generator" || attributes["name"] == "calibre:user_metadata" {
                found.append(Finding(group: .edits, label: "Made with", value: attributes["content"] ?? ""))
            }
            if attributes["property"] == "dcterms:modified" {
                found.append(Finding(group: .edits, label: "Last changed", value: "Saved in the book"))
            }
        }
        return unique(found)
    }

    private static func unique(_ findings: [Finding]) -> [Finding] {
        var seen: Set<String> = []
        return findings.filter { !$0.value.isEmpty && seen.insert("\($0.label)|\($0.value)").inserted }
    }
}

/// Counting and reading start tags without building a tree (comment and change counts).
enum XMLTags {
    static func count(_ data: Data, _ tag: String) -> Int {
        attributes(data, tag, limit: 1_000_000).count
    }

    /// The attributes of every `<tag …>` element, in order.
    static func attributes(_ data: Data, _ tag: String, limit: Int = 10_000) -> [[String: String]] {
        let collector = Collector(tag: tag, limit: limit)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        parser.parse()
        return collector.found
    }

    private final class Collector: NSObject, XMLParserDelegate {
        let tag: String
        let limit: Int
        var found: [[String: String]] = []
        init(tag: String, limit: Int) {
            self.tag = tag
            self.limit = limit
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            guard name == tag else { return }
            found.append(attributes)
            if found.count >= limit { parser.abortParsing() }
        }
    }
}
