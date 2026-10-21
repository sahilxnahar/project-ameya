import AmeyaCore
import CoreGraphics
import Foundation
import PDFKit

/// Hidden details in PDFs: the Info dictionary, XMP, attachments, form answers, scripts, comments
/// and earlier saved versions. Cleaning writes the pages into a fresh document, which leaves the
/// Info dictionary, XMP and earlier versions behind while keeping text, pictures and comments.
enum PDFPrivacy {
    typealias Finding = PrivacyReport.Finding
    static let maxPages = 5_000

    static func inspect(_ url: URL) throws -> PrivacyReport {
        guard let document = CGPDFDocument(url as CFURL) else { throw ConversionError.unreadable }
        if document.isEncrypted, !document.isUnlocked, !document.unlockWithPassword("") {
            return PrivacyReport(kind: .pdf, canClean: false,
                                 kept: ["This PDF has a password, so Ameya can't look inside. Use “Remove password…” first."])
        }
        var found: [Finding] = []
        if let info = document.info { found += infoFindings(info) }
        if let catalog = document.catalog {
            found += xmpFindings(catalog)
            found += catalogFindings(catalog)
        }
        found += pageFindings(document)
        let saves = countSaves(url)
        if saves > 1 {
            found.append(Finding(group: .edits, label: "Saved versions inside",
                                 value: "\(saves) — earlier versions may still be readable"))
        }
        var kept: [String] = []
        if found.contains(where: { ["Attached files", "Form answers", "Comments", "Scripts"].contains($0.label) }) {
            kept.append(ConversionNote.pdfContentKept.message)
        }
        return PrivacyReport(kind: .pdf, findings: found, canClean: true, kept: kept)
    }

    // MARK: Info and XMP

    private static func infoFindings(_ info: CGPDFDictionaryRef) -> [Finding] {
        var found: [Finding] = []
        let labels: [String: (PrivacyReport.Group, String)] = [
            "Author": (.name, "Author"), "Creator": (.edits, "Made with"), "Producer": (.edits, "Saved by"),
            "CreationDate": (.edits, "Created"), "ModDate": (.edits, "Last changed"), "Title": (.other, "Title"),
            "Subject": (.other, "Subject"), "Keywords": (.other, "Keywords"),
        ]
        CGPDFDictionaryApplyBlock(info, { key, object, _ in
            let name = String(cString: key)
            guard let text = PDFValue.text(object), !text.isEmpty else { return true }
            let (group, label) = labels[name] ?? (.other, "Custom detail “\(name)”")
            let value = name.hasSuffix("Date") ? PDFValue.readableDate(text) : text
            found.append(Finding(group: group, label: label, value: value))
            return found.count < 100
        }, nil)
        return found
    }

    private static func xmpFindings(_ catalog: CGPDFDictionaryRef) -> [Finding] {
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream else { return [] }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data?, data.count < 8 << 20 else { return [] }
        var found = [Finding(group: .other, label: "Extra details (XMP)", value: "Present")]
        for (name, value) in XMLLeaves.collect(data, limit: 500) {
            switch name {
            case "dc:creator": found.append(Finding(group: .name, label: "Author", value: value))
            case "xmp:CreatorTool": found.append(Finding(group: .edits, label: "Made with", value: value))
            case "pdf:Producer": found.append(Finding(group: .edits, label: "Saved by", value: value))
            case "xmpMM:History", "stEvt:action": found.append(Finding(group: .edits, label: "Edit history", value: "Present"))
            case "xmpMM:DocumentID", "xmpMM:InstanceID": found.append(Finding(group: .other, label: "File ID that can link copies", value: value))
            default: break
            }
        }
        var seen: Set<String> = []
        return found.filter { seen.insert($0.label + $0.value).inserted }
    }

    // MARK: Attachments, forms, scripts

    private static func catalogFindings(_ catalog: CGPDFDictionaryRef) -> [Finding] {
        var found: [Finding] = []
        var names: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names {
            var files: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(names, "EmbeddedFiles", &files), let files {
                let attached = PDFValue.nameTreeKeys(files)
                if !attached.isEmpty {
                    found.append(Finding(group: .other, label: "Attached files", value: attached.prefix(20).joined(separator: ", ")))
                }
            }
            var scripts: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(names, "JavaScript", &scripts), scripts != nil {
                found.append(Finding(group: .other, label: "Scripts", value: "This PDF contains JavaScript"))
            }
        }
        var open: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "OpenAction", &open), let open, PDFValue.name(open, "S") == "JavaScript",
           !found.contains(where: { $0.label == "Scripts" }) {
            found.append(Finding(group: .other, label: "Scripts", value: "Runs JavaScript when opened"))
        }
        var form: CGPDFDictionaryRef?
        var fields: CGPDFArrayRef?
        if CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form,
           CGPDFDictionaryGetArray(form, "Fields", &fields), let fields {
            var filled = 0
            for index in 0..<min(CGPDFArrayGetCount(fields), 2_000) {
                var field: CGPDFDictionaryRef?
                var value: CGPDFObjectRef?
                if CGPDFArrayGetDictionary(fields, index, &field), let field,
                   CGPDFDictionaryGetObject(field, "V", &value), let value, PDFValue.text(value)?.isEmpty == false {
                    filled += 1
                }
            }
            if filled > 0 {
                found.append(Finding(group: .other, label: "Form answers", value: "\(filled) filled-in field\(filled == 1 ? "" : "s")"))
            } else if CGPDFArrayGetCount(fields) > 0 {
                found.append(Finding(group: .other, label: "Form fields", value: "\(CGPDFArrayGetCount(fields)) (empty)"))
            }
        }
        return found
    }

    /// Comments and their authors. Links and form widgets aren't comments.
    private static func pageFindings(_ document: CGPDFDocument) -> [Finding] {
        var comments = 0
        var authors: [String] = []
        for number in 1...max(1, min(document.numberOfPages, maxPages)) {
            guard let page = document.page(at: number)?.dictionary else { continue }
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(page, "Annots", &annotations), let annotations else { continue }
            for index in 0..<min(CGPDFArrayGetCount(annotations), 1_000) {
                var annotation: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation,
                      let subtype = PDFValue.name(annotation, "Subtype"),
                      !["Link", "Widget", "Popup"].contains(subtype) else { continue }
                comments += 1
                var author: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(annotation, "T", &author), let author, let name = PDFValue.text(author),
                   !name.isEmpty, !authors.contains(name), authors.count < 20 {
                    authors.append(name)
                }
            }
        }
        var found: [Finding] = []
        if comments > 0 { found.append(Finding(group: .other, label: "Comments", value: "\(comments) comment\(comments == 1 ? "" : "s") or markup")) }
        if !authors.isEmpty { found.append(Finding(group: .name, label: "Comment authors", value: authors.joined(separator: ", "))) }
        return found
    }

    /// Each incremental save appends "%%EOF"; several mean earlier versions are still in the file.
    static func countSaves(_ url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        let marker = Data("%%EOF".utf8)
        var count = 0
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            let window = carry + chunk
            var start = window.startIndex
            while let range = window.range(of: marker, in: start..<window.endIndex) {
                count += 1
                start = range.upperBound
            }
            // Keep the tail so a marker split across chunks is found once, never twice.
            carry = Data(window.suffix(from: max(start, window.endIndex - (marker.count - 1))))
        }
        return count
    }

    // MARK: Cleaning

    @MainActor
    static func clean(_ input: URL, output: URL) throws -> [ConversionNote] {
        guard let source = PDFDocument(url: input) else { throw ConversionError.unreadable }
        if source.isLocked {
            throw ConversionError.refused("This PDF has a password. Use “Remove password…” first, then remove its hidden details.")
        }
        let report = try? inspect(input)
        let fresh = PDFDocument()
        for index in 0..<min(source.pageCount, maxPages) {
            guard let page = source.page(at: index)?.copy() as? PDFPage else { continue }
            for annotation in page.annotations {
                annotation.userName = nil // who wrote a comment
                annotation.modificationDate = nil
            }
            fresh.insert(page, at: fresh.pageCount)
        }
        guard fresh.pageCount > 0 else { throw ConversionError.invalidData("the PDF has no pages") }
        fresh.documentAttributes = [:]
        guard fresh.write(to: output) else { throw ConversionError.encodeFailed(.pdf) }
        var notes: [ConversionNote] = [.hiddenDetailsRemoved]
        if report?.kept.isEmpty == false { notes.append(.pdfContentKept) }
        if source.outlineRoot.map({ $0.numberOfChildren > 0 }) == true { notes.append(.pdfBookmarksDropped) }
        return notes
    }
}

/// Small readers for CGPDF objects.
enum PDFValue {
    static func text(_ object: CGPDFObjectRef) -> String? {
        var string: CGPDFStringRef?
        if CGPDFObjectGetValue(object, .string, &string), let string {
            return (CGPDFStringCopyTextString(string) as String?).map { PrivacyReport.clip($0) }
        }
        var name: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .name, &name), let name { return String(cString: name) }
        return nil
    }

    static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var name: UnsafePointer<CChar>?
        return CGPDFDictionaryGetName(dictionary, key, &name) ? name.map { String(cString: $0) } : nil
    }

    /// The keys of a PDF name tree (e.g. attached file names), following /Kids a few levels deep.
    static func nameTreeKeys(_ node: CGPDFDictionaryRef, depth: Int = 0) -> [String] {
        guard depth < 8 else { return [] }
        var keys: [String] = []
        var names: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Names", &names), let names {
            var index = 0
            while index < min(CGPDFArrayGetCount(names), 2_000) {
                var object: CGPDFObjectRef?
                if CGPDFArrayGetObject(names, index, &object), let object, let key = text(object) { keys.append(key) }
                index += 2
            }
        }
        var kids: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
            for index in 0..<min(CGPDFArrayGetCount(kids), 200) {
                var kid: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(kids, index, &kid), let kid { keys += nameTreeKeys(kid, depth: depth + 1) }
            }
        }
        return keys
    }

    /// "D:20240501103000+01'00'" → "2024-05-01 10:30".
    static func readableDate(_ text: String) -> String {
        let digits = Array((text.hasPrefix("D:") ? text.dropFirst(2) : Substring(text)).prefix(while: \.isNumber).prefix(12))
        guard digits.count >= 8 else { return text }
        func part(_ from: Int, _ to: Int) -> String { String(digits[from..<to]) }
        let date = "\(part(0, 4))-\(part(4, 6))-\(part(6, 8))"
        return digits.count >= 12 ? "\(date) \(part(8, 10)):\(part(10, 12))" : date
    }
}

/// Leaf elements and attributes of an XML document, as (qualified name, text) pairs.
/// Used for XMP and Office/EPUB metadata. External entities are never loaded.
final class XMLLeaves: NSObject, XMLParserDelegate {
    private var pairs: [(String, String)] = []
    private var stack: [(name: String, text: String)] = []
    private let limit: Int

    private init(limit: Int) { self.limit = limit }

    static func collect(_ data: Data, limit: Int = 2_000) -> [(String, String)] {
        let collector = XMLLeaves(limit: limit)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = collector
        parser.parse()
        return collector.pairs
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        for (key, value) in attributes where !key.hasPrefix("xmlns") && !value.isEmpty {
            pairs.append((key, PrivacyReport.clip(value)))
        }
        stack.append((name, ""))
        if pairs.count >= limit { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty, stack[stack.count - 1].text.count < 4_000 else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard let element = stack.popLast() else { return }
        let text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            // rdf:li values belong to the property that holds them (dc:creator → Seq → li).
            let owner = element.name == "rdf:li" ? stack.last(where: { !$0.name.hasPrefix("rdf:") })?.name ?? element.name : element.name
            pairs.append((owner, PrivacyReport.clip(text)))
        }
        if pairs.count >= limit { parser.abortParsing() }
    }
}
