import AmeyaCore
import Foundation

/// Converts data files. CSV, TSV, JSON, property lists and XML are read; those plus YAML,
/// XLSX, and HTML or Markdown tables are written. Tables (rows, first row the header) and
/// trees (JSON-like values) meet in the middle: a table becomes an array of objects, and a
/// tree becomes a table by flattening nested keys into "a.b" columns.
enum DataConverter {
    static let maxInputBytes = 200 << 20

    enum Content {
        case table([[DataValue]])
        case tree(DataValue)
    }

    static func convert(input: URL, from source: FileFormat, to target: FileFormat, output: URL) throws -> [ConversionNote] {
        let data: Data
        do {
            data = try Data(contentsOf: input, options: .mappedIfSafe)
        } catch {
            throw ConversionError.unreadable
        }
        var notes: Set<ConversionNote> = []
        let content = try read(data, as: source, notes: &notes)
        try write(content, as: target, to: output, notes: &notes)
        return notes.sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: Reading

    static func read(_ data: Data, as source: FileFormat, notes: inout Set<ConversionNote>) throws -> Content {
        guard data.count <= maxInputBytes else {
            throw ConversionError.dataLimit("data files are limited to \(maxInputBytes >> 20) MB")
        }
        switch source {
        case .csv, .tsv:
            let rows = try DelimitedText.parse(DelimitedText.decode(data), delimiter: source == .tsv ? DelimitedText.tab : nil)
            guard !rows.isEmpty else { throw ConversionError.invalidData("it has no rows") }
            return .table(rows.map { $0.map(DataValue.string) })
        case .json:
            return .tree(try JSONReader.parse(DelimitedText.decode(data)))
        case .plist:
            let (value, simplified) = try PropertyListData.read(data)
            if simplified { notes.insert(.datesAndDataAsText) }
            return .tree(value)
        case .xml:
            notes.insert(.xmlStructureMapped)
            return .tree(try XMLTreeReader.read(data))
        default:
            throw ConversionError.unsupportedConversion(from: source, to: .json)
        }
    }

    // MARK: Writing

    static func write(_ content: Content, as target: FileFormat, to url: URL, notes: inout Set<ConversionNote>) throws {
        switch target {
        case .json:
            try JSONWriter.write(tree(content, notes: &notes)).write(to: url)
        case .yaml:
            try YAMLWriter.write(tree(content, notes: &notes)).write(to: url)
        case .plist:
            let (data, nullsRemoved) = try PropertyListData.write(tree(content, notes: &notes))
            if nullsRemoved { notes.insert(.nullsRemoved) }
            try data.write(to: url)
        case .xml:
            let (data, namesAdjusted) = XMLTreeWriter.write(try tree(content, notes: &notes))
            if namesAdjusted { notes.insert(.xmlNamesAdjusted) }
            try data.write(to: url)
        case .csv, .tsv:
            try DelimitedText.write(try table(content, notes: &notes), delimiter: target == .tsv ? DelimitedText.tab : DelimitedText.comma)
                .write(to: url)
        case .xlsx:
            var rows = try table(content, notes: &notes)
            if case .table = content { // CSV cells are text; give the spreadsheet real numbers.
                for index in rows.indices.dropFirst() {
                    rows[index] = rows[index].map { if case .string(let text) = $0 { .inferred(from: text) } else { $0 } }
                }
            }
            if try XLSXWriter.write(rows, to: url) { notes.insert(.cellsTruncated) }
        case .html:
            try Data(htmlTable(try table(content, notes: &notes)).utf8).write(to: url)
        case .md:
            try Data(markdownTable(try table(content, notes: &notes)).utf8).write(to: url)
        default:
            throw ConversionError.unsupportedTarget(target)
        }
    }

    // MARK: Table ↔ tree

    /// The table's rows as objects keyed by the header row, with typed values.
    static func tree(_ content: Content, notes: inout Set<ConversionNote>) throws -> DataValue {
        guard case .table(let table) = content else {
            if case .tree(let value) = content { return value }
            return .null
        }
        notes.insert(.tableValuesTyped)
        guard let header = table.first else { return .array([]) }
        var keys: [String] = []
        var used: Set<String> = []
        for (index, cell) in header.enumerated() {
            let name = DelimitedText.cellText(cell)
            keys.append(uniqueKey(name.isEmpty ? "column \(index + 1)" : name, used: &used))
        }
        return .array(table.dropFirst().map { row in
            var fields = keys.enumerated().map { index, key in
                DataValue.Field(key: key, value: index < row.count ? typed(row[index]) : .null)
            }
            for index in keys.count..<max(keys.count, row.count) { // cells past the header
                fields.append(.init(key: "column \(index + 1)", value: typed(row[index])))
            }
            return .object(fields)
        })
    }

    private static func typed(_ cell: DataValue) -> DataValue {
        if case .string(let text) = cell { return .inferred(from: text) }
        return cell
    }

    private static func uniqueKey(_ name: String, used: inout Set<String>) -> String {
        var candidate = name
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(name) \(suffix)"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }

    /// A tree as rows: arrays of objects become one row per object with the union of their
    /// (flattened) keys as columns; arrays of arrays are taken as rows directly.
    static func table(_ content: Content, notes: inout Set<ConversionNote>) throws -> [[DataValue]] {
        switch content {
        case .table(let rows):
            return rows
        case .tree(var value):
            // An API envelope like {"data": [...]} holds the real table.
            if case .object(let fields) = value, fields.count == 1, case .array = fields[0].value {
                value = fields[0].value
            }
            var flattened = false
            let rows = try rows(of: value, flattened: &flattened)
            if flattened { notes.insert(.nestedDataFlattened) }
            return rows
        }
    }

    private static func rows(of value: DataValue, flattened: inout Bool) throws -> [[DataValue]] {
        let items: [DataValue]
        switch value {
        case .array(let array): items = array
        case .object: items = [value]
        default: return [[.string("value")], [value]]
        }
        guard items.count < DelimitedText.maxRows else { throw ConversionError.dataLimit("it has more than \(DelimitedText.maxRows) rows") }

        if !items.isEmpty, items.allSatisfy({ if case .array = $0 { true } else { false } }) {
            return items.map { item in
                guard case .array(let cells) = item else { return [] }
                return cells.map { cell in
                    if cell.isContainer { flattened = true }
                    return cell
                }
            }
        }

        var columns: [String] = []
        var positions: [String: Int] = [:]
        var records: [[String: DataValue]] = []
        for item in items {
            var record: [String: DataValue] = [:]
            var cells: [(String, DataValue)] = []
            if case .object(let fields) = item {
                flatten(fields, prefix: "", into: &cells, flattened: &flattened)
            } else {
                cells = [("value", item)]
            }
            for (key, cell) in cells {
                if positions[key] == nil {
                    positions[key] = columns.count
                    columns.append(key)
                    guard columns.count <= DelimitedText.maxColumns else {
                        throw ConversionError.dataLimit("it would need more than \(DelimitedText.maxColumns) columns")
                    }
                }
                record[key] = cell
            }
            records.append(record)
        }
        return [columns.map(DataValue.string)] + records.map { record in columns.map { record[$0] ?? .null } }
    }

    private static func flatten(_ fields: [DataValue.Field], prefix: String, into cells: inout [(String, DataValue)], flattened: inout Bool) {
        for field in fields {
            let key = prefix + field.key
            switch field.value {
            case .object(let nested) where !nested.isEmpty:
                flattened = true
                flatten(nested, prefix: key + ".", into: &cells, flattened: &flattened)
            case .array, .object:
                flattened = true
                cells.append((key, field.value)) // written as JSON text in one cell
            default:
                cells.append((key, field.value))
            }
        }
    }

    // MARK: Document tables

    static func htmlTable(_ rows: [[DataValue]]) -> String {
        let width = rows.map(\.count).max() ?? 0
        func cells(_ row: [DataValue], tag: String) -> String {
            (0..<width).map { index in
                let text = index < row.count ? DelimitedText.cellText(row[index]) : ""
                return "<\(tag)>\(XMLTreeWriter.escape(text).replacingOccurrences(of: "\n", with: "<br>"))</\(tag)>"
            }.joined()
        }
        var out = """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"><title>Table</title><style>
            table{border-collapse:collapse;font:14px -apple-system,sans-serif}
            th,td{border:1px solid #ccc;padding:4px 8px;text-align:left;vertical-align:top}
            th{background:#f4f4f4}
            </style></head><body>
            <table>

            """
        if let header = rows.first {
            out += "<thead><tr>\(cells(header, tag: "th"))</tr></thead>\n<tbody>\n"
            for row in rows.dropFirst() { out += "<tr>\(cells(row, tag: "td"))</tr>\n" }
            out += "</tbody>\n"
        }
        return out + "</table>\n</body></html>\n"
    }

    /// A GitHub-style pipe table. Pipes are escaped and line breaks become `<br>`.
    static func markdownTable(_ rows: [[DataValue]]) -> String {
        let width = max(rows.map(\.count).max() ?? 0, 1)
        func line(_ row: [DataValue]) -> String {
            let cells = (0..<width).map { index -> String in
                let text = index < row.count ? DelimitedText.cellText(row[index]) : ""
                return text.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "|", with: "\\|")
                    .replacingOccurrences(of: "\r\n", with: "<br>")
                    .replacingOccurrences(of: "\n", with: "<br>")
            }
            return "| " + cells.joined(separator: " | ") + " |\n"
        }
        guard let header = rows.first else { return "" }
        var out = line(header)
        out += "|" + String(repeating: " --- |", count: width) + "\n"
        for row in rows.dropFirst() { out += line(row) }
        return out
    }
}
