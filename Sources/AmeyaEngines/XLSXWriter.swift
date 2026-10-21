import AmeyaCore
import CArchive
import Foundation

/// Writes a minimal Office Open XML workbook: one sheet, inline strings, numbers as numbers,
/// a bold and frozen header row. Zipped with the system libarchive.
enum XLSXWriter {
    static let maxRows = 1_048_576
    static let maxColumns = 16_384
    static let maxCellLength = 32_767

    /// Returns whether any cell had to be shortened to Excel's 32,767-character limit.
    static func write(_ rows: [[DataValue]], to url: URL) throws -> Bool {
        guard rows.count <= maxRows else { throw ConversionError.dataLimit("Excel sheets hold at most \(maxRows) rows") }
        var truncated = false
        let sheet = try sheetXML(rows, truncated: &truncated)
        try zip([
            ("[Content_Types].xml", contentTypes),
            ("_rels/.rels", rootRelationships),
            ("xl/workbook.xml", workbook),
            ("xl/_rels/workbook.xml.rels", workbookRelationships),
            ("xl/styles.xml", styles),
            ("xl/worksheets/sheet1.xml", sheet),
        ], to: url)
        return truncated
    }

    static func sheetXML(_ rows: [[DataValue]], truncated: inout Bool) throws -> Data {
        var out = header + "<worksheet xmlns=\"\(mainNamespace)\">"
        if rows.count > 1 {
            out += "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>"
        }
        out += "<sheetData>"
        for (rowIndex, row) in rows.enumerated() {
            guard row.count <= maxColumns else { throw ConversionError.dataLimit("Excel sheets hold at most \(maxColumns) columns") }
            let number = rowIndex + 1
            out += "<row r=\"\(number)\">"
            let style = rowIndex == 0 ? " s=\"1\"" : ""
            for (columnIndex, value) in row.enumerated() {
                let reference = columnName(columnIndex) + String(number)
                switch value {
                case .null:
                    continue
                case .bool(let flag):
                    out += "<c r=\"\(reference)\"\(style) t=\"b\"><v>\(flag ? 1 : 0)</v></c>"
                case .number(let text):
                    out += "<c r=\"\(reference)\"\(style)><v>\(text)</v></c>"
                case .string, .array, .object:
                    var text = DelimitedText.cellText(value)
                    if text.utf16.count > maxCellLength {
                        text = String(text.prefix(maxCellLength - 1)) // conservative: some characters take two UTF-16 units
                        while text.utf16.count > maxCellLength { text.removeLast() }
                        truncated = true
                    }
                    out += "<c r=\"\(reference)\"\(style) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(XMLTreeWriter.escape(text))</t></is></c>"
                }
            }
            out += "</row>"
        }
        out += "</sheetData></worksheet>"
        return Data(out.utf8)
    }

    /// 0 → A, 25 → Z, 26 → AA.
    static func columnName(_ index: Int) -> String {
        var index = index + 1
        var name = ""
        while index > 0 {
            let remainder = (index - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            index = (index - 1) / 26
        }
        return name
    }

    private static func zip(_ parts: [(String, Data)], to url: URL) throws {
        guard let writer = archive_write_new() else { throw ConversionError.encodeFailed(.xlsx) }
        defer { archive_write_free(writer) }
        guard archive_write_set_format_zip(writer) == ARCHIVE_OK,
              archive_write_open_filename(writer, url.path) == ARCHIVE_OK else {
            throw ConversionError.encodeFailed(.xlsx)
        }
        let now = time(nil)
        for (path, data) in parts {
            guard let entry = archive_entry_new() else { throw ConversionError.encodeFailed(.xlsx) }
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname_utf8(entry, path)
            archive_entry_set_filetype(entry, UInt32(AE_IFREG))
            archive_entry_set_perm(entry, 0o644)
            archive_entry_set_size(entry, Int64(data.count))
            archive_entry_set_mtime(entry, now, 0)
            guard archive_write_header(writer, entry) == ARCHIVE_OK else { throw ConversionError.encodeFailed(.xlsx) }
            let written = data.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) }
            guard written == data.count else { throw ConversionError.encodeFailed(.xlsx) }
        }
        guard archive_write_close(writer) == ARCHIVE_OK else { throw ConversionError.encodeFailed(.xlsx) }
    }

    // MARK: Fixed package parts

    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    private static let mainNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relationshipType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let packageRelationships = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let officeType = "application/vnd.openxmlformats-officedocument.spreadsheetml"

    private static let contentTypes = Data((header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="\(officeType).sheet.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="\(officeType).worksheet+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="\(officeType).styles+xml"/>\
        </Types>
        """).utf8)

    private static let rootRelationships = Data((header + """
        <Relationships xmlns="\(packageRelationships)">\
        <Relationship Id="rId1" Type="\(relationshipType)/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """).utf8)

    private static let workbook = Data((header + """
        <workbook xmlns="\(mainNamespace)" xmlns:r="\(relationshipType)">\
        <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
        """).utf8)

    private static let workbookRelationships = Data((header + """
        <Relationships xmlns="\(packageRelationships)">\
        <Relationship Id="rId1" Type="\(relationshipType)/worksheet" Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId2" Type="\(relationshipType)/styles" Target="styles.xml"/>\
        </Relationships>
        """).utf8)

    private static let styles = Data((header + """
        <styleSheet xmlns="\(mainNamespace)">\
        <fonts count="2"><font><sz val="12"/><name val="Calibri"/></font><font><b/><sz val="12"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
        </styleSheet>
        """).utf8)
}
