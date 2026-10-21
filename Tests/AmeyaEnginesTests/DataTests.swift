import AmeyaCore
import Foundation
import Testing
@testable import AmeyaEngines

@Suite("Delimited text")
struct DelimitedTextTests {
    @Test func quotesCommasAndNewlinesInsideFields() throws {
        let csv = "name,quote,notes\r\n\"Smith, Ann\",\"She said \"\"hi\"\"\",\"line one\nline two\"\r\nBob,,plain\r\n"
        let rows = try DelimitedText.parse(csv, delimiter: nil)
        #expect(rows == [
            ["name", "quote", "notes"],
            ["Smith, Ann", "She said \"hi\"", "line one\nline two"],
            ["Bob", "", "plain"],
        ])
    }

    @Test func byteOrderMarkLineEndingsAndBlankLines() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("a,b\r1,2\n\n3,4".utf8)
        #expect(try DelimitedText.parse(DelimitedText.decode(data), delimiter: nil) == [["a", "b"], ["1", "2"], ["3", "4"]])
        let utf16 = "x,y\nü,ß".data(using: .utf16)! // carries a BOM
        #expect(try DelimitedText.parse(DelimitedText.decode(utf16), delimiter: nil) == [["x", "y"], ["ü", "ß"]])
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9]) // "café" in Windows Latin-1
        #expect(DelimitedText.decode(latin1) == "café")
    }

    @Test func europeanSemicolonsAreDetected() throws {
        #expect(try DelimitedText.parse("Name;Preis\nKäse;3,50\n", delimiter: nil) == [["Name", "Preis"], ["Käse", "3,50"]])
        #expect(try DelimitedText.parse("sep=;\na;b\n", delimiter: nil) == [["a", "b"]])
        // Commas inside quotes don't count.
        #expect(DelimitedText.detectDelimiter(Array("\"a,b,c\";d;e".utf8)) == DelimitedText.semicolon)
    }

    @Test func tabsAndRaggedRows() throws {
        #expect(try DelimitedText.parse("a\tb\n1\n1\t2\t3", delimiter: DelimitedText.tab) == [["a", "b"], ["1"], ["1", "2", "3"]])
    }

    @Test func writingThenReadingGivesTheSameCells() throws {
        let rows: [[DataValue]] = [
            [.string("plain"), .string("with, comma"), .string("with \"quote\""), .string("two\nlines")],
            [.string(" padded "), .string(""), .string("Zoë 😀"), .number("1.5")],
            [.string("")],
        ]
        for delimiter in [DelimitedText.comma, DelimitedText.tab] {
            let text = String(decoding: DelimitedText.write(rows, delimiter: delimiter), as: UTF8.self)
            let back = try DelimitedText.parse(text, delimiter: delimiter)
            #expect(back == rows.map { $0.map(DelimitedText.cellText) })
        }
    }

    @Test func unclosedQuotesAreRejected() {
        #expect(throws: ConversionError.invalidData("a quoted field that starts on line 2 is never closed")) {
            try DelimitedText.parse("a,b\n\"oops,1\n2,3\n", delimiter: nil)
        }
    }

    @Test func rowLimitIsEnforced() {
        #expect(throws: ConversionError.self) {
            try DelimitedText.parse("a\n1\n2\n3\n", delimiter: nil, maxRows: 2)
        }
    }

    @Test func cellsAreTypedConservatively() {
        #expect(DataValue.inferred(from: "42") == .number("42"))
        #expect(DataValue.inferred(from: "-3.25e2") == .number("-3.25e2"))
        #expect(DataValue.inferred(from: "007") == .string("007")) // ZIP codes and IDs keep their zeros
        #expect(DataValue.inferred(from: "4111111111111111") == .string("4111111111111111")) // too many digits
        #expect(DataValue.inferred(from: "1,000") == .string("1,000"))
        #expect(DataValue.inferred(from: "+1") == .string("+1"))
        #expect(DataValue.inferred(from: "TRUE") == .bool(true))
        #expect(DataValue.inferred(from: "") == .null)
    }
}

@Suite("JSON")
struct JSONTests {
    @Test func keepsKeyOrderNumbersAndEscapes() throws {
        let value = try JSONReader.parse(#"{"b": 12345678901234567890, "a": "tab\t\"q\" \u00e9 \ud83d\ude00", "c": [true, null, -0.5e10]}"#)
        #expect(value == .object([
            .init(key: "b", value: .number("12345678901234567890")),
            .init(key: "a", value: .string("tab\t\"q\" é 😀")),
            .init(key: "c", value: .array([.bool(true), .null, .number("-0.5e10")])),
        ]))
    }

    @Test func lastDuplicateKeyWins() throws {
        #expect(try JSONReader.parse(#"{"a": 1, "a": 2}"#) == .object([.init(key: "a", value: .number("2"))]))
    }

    @Test("Malformed JSON is rejected", arguments: [
        "", "{", "[1,]", "{'a': 1}", "{\"a\" 1}", "[01]", "[1.]", "\"unterminated", "[1] [2]", "nul", "{\"a\": \"\t\"}",
    ])
    func malformed(text: String) {
        #expect(throws: ConversionError.self) { try JSONReader.parse(text) }
    }

    @Test func deepNestingIsRefused() {
        let deep = String(repeating: "[", count: 600) + String(repeating: "]", count: 600)
        #expect(throws: ConversionError.self) { try JSONReader.parse(deep) }
    }

    @Test func writerOutputIsValidSortedAndRoundTrips() throws {
        let value = try JSONReader.parse(#"{"z": {"y": [], "x": {}}, "a": "line\nbreak \u0001", "n": 1e3}"#)
        let data = JSONWriter.write(value)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("{\n  \"a\": \"line\\nbreak \\u0001\",\n  \"n\": 1e3,\n  \"z\": {\n    \"x\": {},\n    \"y\": []\n  }\n}"))
        #expect(try JSONSerialization.jsonObject(with: data) is [String: Any])
        #expect(try JSONReader.parse(text) == sorted(value))
    }

    private func sorted(_ value: DataValue) -> DataValue {
        switch value {
        case .object(let fields): .object(fields.sorted { $0.key < $1.key }.map { .init(key: $0.key, value: sorted($0.value)) })
        case .array(let items): .array(items.map(sorted))
        default: value
        }
    }
}

@Suite("Data conversions", .serialized)
struct DataConversionTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func convert(_ data: Data, from source: FileFormat, to target: FileFormat) throws -> (Data, [ConversionNote]) {
        let input = directory.appendingPathComponent("in-\(UUID().uuidString).\(source.preferredExtension)")
        let output = directory.appendingPathComponent("out-\(UUID().uuidString).\(target.preferredExtension)")
        try data.write(to: input)
        let notes = try DataConverter.convert(input: input, from: source, to: target, output: output)
        return (try Data(contentsOf: output), notes)
    }

    private let people = Data("name,age,zip,member,note\nZoë,42,02134,true,\"likes \"\"quotes\"\", commas\"\nBob,3.5,,FALSE,\n".utf8)

    @Test func csvBecomesTypedJSON() throws {
        let (json, notes) = try convert(people, from: .csv, to: .json)
        #expect(notes == [.tableValuesTyped])
        let rows = try #require(try JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        #expect(rows.count == 2)
        #expect(rows[0]["name"] as? String == "Zoë")
        #expect(rows[0]["age"] as? Int == 42)
        #expect(rows[0]["zip"] as? String == "02134")
        #expect(rows[0]["member"] as? Bool == true)
        #expect(rows[0]["note"] as? String == "likes \"quotes\", commas")
        #expect(rows[1]["age"] as? Double == 3.5)
        #expect(rows[1]["zip"] is NSNull)
    }

    @Test func csvJSONCSVRoundTripKeepsCells() throws {
        let csv = "id,text\n1,\"multi\nline\"\n2,\"a,b\"\n"
        let (json, _) = try convert(Data(csv.utf8), from: .csv, to: .json)
        let (back, _) = try convert(json, from: .json, to: .csv)
        #expect(try DelimitedText.parse(String(decoding: back, as: UTF8.self), delimiter: nil) == [["id", "text"], ["1", "multi\nline"], ["2", "a,b"]])
    }

    @Test func nestedJSONIsFlattenedIntoDottedColumns() throws {
        let json = #"[{"id": 1, "user": {"name": "Ann", "address": {"city": "Oslo"}}, "tags": ["a", "b"]}, {"id": 2, "extra": "yes"}]"#
        let (csv, notes) = try convert(Data(json.utf8), from: .json, to: .csv)
        #expect(notes == [.nestedDataFlattened])
        #expect(try DelimitedText.parse(String(decoding: csv, as: UTF8.self), delimiter: nil) == [
            ["id", "user.name", "user.address.city", "tags", "extra"],
            ["1", "Ann", "Oslo", "[\"a\",\"b\"]", ""],
            ["2", "", "", "", "yes"],
        ])
    }

    @Test func apiEnvelopesAndScalarArraysBecomeTables() throws {
        let (csv, _) = try convert(Data(#"{"data": [{"a": 1}, {"a": 2}]}"#.utf8), from: .json, to: .tsv)
        #expect(String(decoding: csv, as: UTF8.self) == "a\r\n1\r\n2\r\n")
        let (list, _) = try convert(Data(#"["x", "y"]"#.utf8), from: .json, to: .csv)
        #expect(String(decoding: list, as: UTF8.self) == "value\r\nx\r\ny\r\n")
    }

    @Test func jsonAndPlistRoundTrip() throws {
        let json = #"{"name": "Ameya", "count": 3, "ratio": 0.25, "on": true, "list": [1, "two"], "nested": {"k": "v"}}"#
        let (plist, notes) = try convert(Data(json.utf8), from: .json, to: .plist)
        #expect(notes.isEmpty)
        #expect(FileFormat.sniff(plist) == .plist)
        let (back, _) = try convert(plist, from: .plist, to: .json)
        let original = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! NSDictionary
        #expect(try JSONSerialization.jsonObject(with: back) as! NSDictionary == original)
    }

    @Test func nullsAreLeftOutOfPropertyLists() throws {
        let (plist, notes) = try convert(Data(#"{"a": null, "b": [1, null]}"#.utf8), from: .json, to: .plist)
        #expect(notes == [.nullsRemoved])
        let object = try PropertyListSerialization.propertyList(from: plist, format: nil) as! NSDictionary
        #expect(object == ["b": [1]] as NSDictionary)
    }

    @Test func binaryPlistWithDatesAndData() throws {
        let plist: [String: Any] = [
            "title": "Report", "pages": 12, "draft": false,
            "created": Date(timeIntervalSince1970: 0), "blob": Data([1, 2, 3]),
        ]
        let binary = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        #expect(FileFormat.sniff(binary) == .plist)
        let (json, notes) = try convert(binary, from: .plist, to: .json)
        #expect(notes == [.datesAndDataAsText])
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["title"] as? String == "Report")
        #expect(object["pages"] as? Int == 12)
        #expect(object["draft"] as? Bool == false)
        #expect(object["created"] as? String == "1970-01-01T00:00:00Z")
        #expect(object["blob"] as? String == "AQID")
    }

    @Test func malformedInputIsRejected() {
        #expect(throws: ConversionError.self) { try convert(Data("{\"a\": ".utf8), from: .json, to: .csv) }
        #expect(throws: ConversionError.self) { try convert(Data("not a plist".utf8), from: .plist, to: .json) }
        #expect(throws: ConversionError.self) { try convert(Data("<a><b></a>".utf8), from: .xml, to: .json) }
        #expect(throws: ConversionError.self) { try convert(Data(), from: .csv, to: .json) }
    }

    @Test func xmlBecomesJSON() throws {
        let xml = """
            <?xml version="1.0"?>
            <library city="Oslo">
              <book id="1"><title>Dune</title><year>1965</year></book>
              <book id="2"><title><![CDATA[Fish & Chips]]></title></book>
              <note>Open <b>daily</b></note>
              <empty/>
            </library>
            """
        let (json, notes) = try convert(Data(xml.utf8), from: .xml, to: .json)
        #expect(notes == [.xmlStructureMapped])
        let root = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let library = try #require(root["library"] as? [String: Any])
        #expect(library["@city"] as? String == "Oslo")
        let books = try #require(library["book"] as? [[String: Any]])
        #expect(books.count == 2)
        #expect(books[0]["@id"] as? String == "1")
        #expect(books[0]["title"] as? String == "Dune")
        #expect(books[1]["title"] as? String == "Fish & Chips")
        let note = try #require(library["note"] as? [String: Any])
        #expect(note["#text"] as? String == "Open")
        #expect(note["b"] as? String == "daily")
        #expect(library["empty"] as? String == "")
    }

    @Test func xmlEntityDeclarationsAreRefused() {
        let bomb = "<?xml version=\"1.0\"?><!DOCTYPE l [<!ENTITY a \"aaaa\"><!ENTITY b \"&a;&a;\">]><l>&b;</l>"
        #expect(throws: ConversionError.self) { try convert(Data(bomb.utf8), from: .xml, to: .json) }
    }

    @Test func jsonToXMLAndBack() throws {
        let json = #"{"catalog": {"@version": "2", "item": [{"name": "A & B"}, {"name": "<C>"}], "bad key": "x"}}"#
        let (xml, notes) = try convert(Data(json.utf8), from: .json, to: .xml)
        #expect(notes == [.xmlNamesAdjusted])
        #expect(FileFormat.sniff(xml) == .xml)
        let (back, _) = try convert(xml, from: .xml, to: .json)
        let root = try #require(try JSONSerialization.jsonObject(with: back) as? [String: Any])
        let catalog = try #require(root["catalog"] as? [String: Any])
        #expect(catalog["@version"] as? String == "2")
        #expect((catalog["item"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["A & B", "<C>"])
        #expect(catalog["bad_key"] as? String == "x")
    }

    @Test func yamlQuotesAnythingAmbiguous() throws {
        let json = ##"{"name": "Ann Lee", "answer": "yes", "zip": "02134", "empty": "", "colon": "a: b", "hash": "#tag", "multi": "one\ntwo", "count": 3, "ok": true, "none": null, "tags": ["x", {"k": "v", "w": 1}], "nested": {"deep": {"z": []}}, "café": "naïve"}"##
        let (yaml, notes) = try convert(Data(json.utf8), from: .json, to: .yaml)
        #expect(notes.isEmpty)
        #expect(String(decoding: yaml, as: UTF8.self) == """
            name: Ann Lee
            answer: "yes"
            zip: "02134"
            empty: ""
            colon: "a: b"
            hash: "#tag"
            multi: "one\\ntwo"
            count: 3
            ok: true
            none: null
            tags:
              - x
              - k: v
                w: 1
            nested:
              deep:
                z: []
            café: naïve

            """)
    }

    @Test func csvBecomesAValidWorkbook() throws {
        let (xlsx, notes) = try convert(people, from: .csv, to: .xlsx)
        #expect(notes.isEmpty)
        let file = directory.appendingPathComponent("book.xlsx")
        try xlsx.write(to: file)
        let listing = try run("/usr/bin/tar", ["-tf", file.path])
        let parts = ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels",
                     "xl/styles.xml", "xl/worksheets/sheet1.xml"]
        for part in parts {
            #expect(listing.contains(part))
            // tar reads member names as patterns, so the brackets need escaping.
            let pattern = part.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            let xml = try run("/usr/bin/tar", ["-xOf", file.path, pattern])
            #expect(!xml.isEmpty)
            #expect(XMLParser(data: Data(xml.utf8)).parse(), "\(part) is not well-formed")
        }
        let sheet = try run("/usr/bin/tar", ["-xOf", file.path, "xl/worksheets/sheet1.xml"])
        #expect(sheet.contains(#"<c r="B2"><v>42</v></c>"#))
        #expect(sheet.contains(#"<c r="C2" t="inlineStr"><is><t xml:space="preserve">02134</t></is></c>"#))
        #expect(sheet.contains(#"<c r="D3" t="b"><v>0</v></c>"#))
        #expect(sheet.contains(#"<c r="A1" s="1" t="inlineStr">"#))
        #expect(sheet.contains("likes &quot;quotes&quot;, commas") || sheet.contains("likes \"quotes\", commas"))
        #expect(!sheet.contains(#"r="C3""#)) // empty cells are left out
    }

    @Test func jsonBecomesAWorkbookWithTypedCells() throws {
        let (xlsx, _) = try convert(Data(#"[{"a": 1, "b": "x"}, {"a": 2.5, "b": true}]"#.utf8), from: .json, to: .xlsx)
        let file = directory.appendingPathComponent("json.xlsx")
        try xlsx.write(to: file)
        let sheet = try run("/usr/bin/tar", ["-xOf", file.path, "xl/worksheets/sheet1.xml"])
        #expect(sheet.contains(#"<c r="A3"><v>2.5</v></c>"#))
        #expect(sheet.contains(#"<c r="B3" t="b"><v>1</v></c>"#))
    }

    @Test func columnNames() {
        #expect(XLSXWriter.columnName(0) == "A")
        #expect(XLSXWriter.columnName(25) == "Z")
        #expect(XLSXWriter.columnName(26) == "AA")
        #expect(XLSXWriter.columnName(16_383) == "XFD")
    }

    @Test func tablesBecomeHTMLAndMarkdown() throws {
        let csv = Data("Item,Note\n<b>,a|b\nTwo,\"x\ny\"\n".utf8)
        let (html, _) = try convert(csv, from: .csv, to: .html)
        let page = String(decoding: html, as: UTF8.self)
        #expect(FileFormat.sniff(html) == .html)
        #expect(page.contains("<thead><tr><th>Item</th><th>Note</th></tr></thead>"))
        #expect(page.contains("<tr><td>&lt;b&gt;</td><td>a|b</td></tr>"))
        #expect(page.contains("<td>x<br>y</td>"))
        let (markdown, _) = try convert(csv, from: .csv, to: .md)
        #expect(String(decoding: markdown, as: UTF8.self) == "| Item | Note |\n| --- | --- |\n| <b> | a\\|b |\n| Two | x<br>y |\n")
    }

    @Test func duplicateAndMissingHeadersGetNames() throws {
        let (json, _) = try convert(Data("a,a,\n1,2,3,4\n".utf8), from: .csv, to: .json)
        let rows = try #require(try JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        #expect(Set(rows[0].keys) == ["a", "a 2", "column 3", "column 4"])
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
