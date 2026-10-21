import AmeyaCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AmeyaEngines

/// Runs conversions through `Engine` in fresh scratch folders.
private struct Workbench {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-everyday-\(UUID().uuidString)", isDirectory: true)

    func file(_ name: String, _ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @MainActor
    func convert(_ input: URL, from source: FileFormat, to target: FileFormat, options: ConversionOptions = ConversionOptions())
        async throws -> (URL, ConversionResult) {
        let scratch = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let request = ConversionRequest(source: source, target: target, options: options)
        return try await Engine.convert(input: input, request: request, scratch: scratch) { _ in }
    }
}

@Suite("QR codes")
struct QRCodeTests {
    @Test("Text becomes a crisp QR PNG that decodes back to the same text", arguments: [
        "Hello, Ameya",
        "Grüße aus Köln — 日本語のテキスト ✓ 🎉",
        "https://example.com/path?q=1&lang=de#top",
    ])
    func roundTrip(text: String) async throws {
        let bench = Workbench()
        let input = try bench.file("qr.txt", Data(text.utf8))
        let (png, result) = try await bench.convert(input, from: .txt, to: .png)
        #expect(result.notes == [.madeQRCode])
        #expect(FileFormat.detect(at: png) == .png)
        let source = try #require(CGImageSourceCreateWithURL(png as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width >= QRCode.minimumSide && image.width == image.height)

        let (txt, decodeResult) = try await bench.convert(png, from: .png, to: .txt)
        #expect(decodeResult.notes == [.onlyCodesRead])
        #expect(try String(contentsOf: txt, encoding: .utf8) == text + "\n")
    }

    @Test func quietZoneSurroundsTheCode() throws {
        let modules = try QRCode.matrix(for: "quiet")
        #expect(modules.count == modules[0].count)
        #expect(modules[0][0] && modules.last![0]) // finder patterns touch the trimmed edges
    }

    @Test func textOverCapacityIsRefused() {
        let long = String(repeating: "x", count: QRCode.maxBytes + 1)
        #expect(throws: QRCode.Failure.self) { _ = try QRCode.png(for: long) }
    }

    @Test func imageWithoutCodesSaysSo() throws {
        let png = try Fixtures.encode(Fixtures.frames(1), as: .png)
        #expect(throws: QRCode.Failure.self) { _ = try QRCode.decode(png, options: ConversionOptions()) }
    }
}

@Suite("vCard contacts")
struct VCardTests {
    static let sample = """
    BEGIN:VCARD\r
    VERSION:3.0\r
    N:Müller;José;;;\r
    FN:José Müller\r
    ORG:Ünïcode GmbH;R&D\r
    EMAIL;TYPE=WORK:jose@example.com\r
    EMAIL;TYPE=HOME:jm@example.org\r
    TEL;TYPE=CELL:+49 170 1234567\r
    TEL;TYPE=HOME:+49 30 765432\r
    TEL;TYPE=WORK:+49 30 111\r
    ADR;TYPE=HOME:;;Hauptstraße 5;Berlin;;10115;Germany\r
    BDAY:1985-04-12\r
    NOTE:Met at the conference\\, likes tea.\\nSecond line.\r
    END:VCARD\r
    BEGIN:VCARD\r
    VERSION:4.0\r
    FN:山田 太郎\r
    TEL;VALUE=uri:tel:+81-3-1234-5678\r
    EMAIL:taro@example.jp\r
    END:VCARD\r
    BEGIN:VCARD\r
    VERSION:2.1\r
    N;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:=C5=81ukasz;Zo=C3=AB;;;\r
    TEL;CELL:+48 600 000 000\r
    NOTE;ENCODING=QUOTED-PRINTABLE;CHARSET=UTF-8:Line one=0D=0A=\r
    continued =C3=A9\r
    END:VCARD\r

    """

    @Test func parsesAllVersions() throws {
        let contacts = try VCard.parse(Data(Self.sample.utf8))
        #expect(contacts.count == 3)
        let jose = contacts[0]
        #expect(jose.firstName == "José" && jose.lastName == "Müller")
        #expect(jose.organization == "Ünïcode GmbH, R&D")
        #expect(jose.emails == ["jose@example.com", "jm@example.org"])
        #expect(jose.phones.count == 3)
        #expect(jose.addresses == ["Hauptstraße 5, Berlin, 10115, Germany"])
        #expect(jose.birthday == "1985-04-12")
        #expect(jose.note == "Met at the conference, likes tea.\nSecond line.")
        #expect(contacts[1].firstName == "山田" && contacts[1].lastName == "太郎")
        #expect(contacts[1].phones == ["+81-3-1234-5678"])
        #expect(contacts[2].lastName == "Łukasz" && contacts[2].firstName == "Zoë")
        #expect(contacts[2].note == "Line one\ncontinued é")
    }

    @Test func csvRoundTripKeepsEveryField() async throws {
        let bench = Workbench()
        let vcf = try bench.file("people.vcf", Data(Self.sample.utf8))
        #expect(FileFormat.detect(at: vcf) == .vcf)
        let (csv, result) = try await bench.convert(vcf, from: .vcf, to: .csv)
        #expect(result.notes == [.contactFieldsLimited])
        let text = try String(contentsOf: csv, encoding: .utf8)
        #expect(text.hasPrefix("First Name,Last Name,Organization,Email,Phone,Address,Birthday,Note\r\n"))
        #expect(text.contains("jose@example.com; jm@example.org"))

        let (back, _) = try await bench.convert(csv, from: .csv, to: .vcf)
        #expect(FileFormat.detect(at: back) == .vcf)
        let original = try VCard.parse(Data(Self.sample.utf8))
        let roundTripped = try VCard.parse(Data(contentsOf: back))
        #expect(roundTripped.count == original.count)
        for (a, b) in zip(original, roundTripped) {
            #expect(a.firstName == b.firstName && a.lastName == b.lastName && a.organization == b.organization)
            #expect(a.emails == b.emails && a.phones == b.phones && a.addresses == b.addresses)
            #expect(a.birthday == b.birthday && a.note == b.note)
        }
    }

    @Test func jsonListsContacts() async throws {
        let bench = Workbench()
        let vcf = try bench.file("people.vcf", Data(Self.sample.utf8))
        let (json, _) = try await bench.convert(vcf, from: .vcf, to: .json)
        let objects = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [[String: Any]])
        #expect(objects.count == 3)
        #expect(objects[0]["emails"] as? [String] == ["jose@example.com", "jm@example.org"])
        #expect(objects[1]["fullName"] as? String == "山田 太郎")
    }

    @Test func utf16AndLongLinesAreHandled() throws {
        let note = String(repeating: "ü", count: 120)
        let written = VCard.write([Contact(firstName: "A", lastName: "B", note: note)])
        #expect(String(decoding: written, as: UTF8.self).components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 })
        #expect(try VCard.parse(written).first?.note == note)
        let utf16 = Self.sample.data(using: .utf16LittleEndian)!
        #expect(try VCard.parse(utf16).count == 3)
    }

    @Test func csvWithoutContactColumnsIsRefused() {
        #expect(throws: ConversionError.self) { _ = try VCard.contacts(fromCSV: Data("a,b\n1,2\n".utf8)) }
    }
}

@Suite("GPS tracks")
struct GeoTrackTests {
    static let gpx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
      <metadata><name>Ignored</name><time>2024-01-01T00:00:00Z</time></metadata>
      <wpt lat="47.6062" lon="-122.3321"><ele>56.2</ele><time>2024-05-01T08:00:00Z</time><name>Start &amp; café</name></wpt>
      <wpt lat="-33.8688" lon="151.2093"><name>Sydney</name></wpt>
      <rte><name>Plan</name>
        <rtept lat="47.1" lon="-122.1"/><rtept lat="47.2" lon="-122.2"><ele>10</ele></rtept><rtept lat="47.3" lon="-122.3"/>
      </rte>
      <trk><name>Morning ride</name>
        <trkseg>
          <trkpt lat="47.60621" lon="-122.33207"><ele>12.5</ele><time>2024-05-01T08:00:00Z</time></trkpt>
          <trkpt lat="47.60635" lon="-122.33190"><ele>13</ele><time>2024-05-01T08:00:05.250Z</time></trkpt>
        </trkseg>
        <trkseg>
          <trkpt lat="47.61" lon="-122.34"><ele>20.75</ele><time>2024-05-01T08:10:00Z</time></trkpt>
        </trkseg>
      </trk>
    </gpx>
    """

    @Test func gpxToKMLToGeoJSONToGPXKeepsEverything() async throws {
        let bench = Workbench()
        let original = try GeoXML.readGPX(Data(Self.gpx.utf8))
        #expect(original.pointCount == 8)
        #expect(original.waypoints[0].name == "Start & café")

        let gpx = try bench.file("ride.gpx", Data(Self.gpx.utf8))
        #expect(FileFormat.detect(at: gpx) == .gpx)
        let (kml, kmlResult) = try await bench.convert(gpx, from: .gpx, to: .kml)
        #expect(kmlResult.notes.isEmpty)
        #expect(FileFormat.detect(at: kml) == .kml)
        let (geojson, _) = try await bench.convert(kml, from: .kml, to: .geojson)
        #expect(FileFormat.detect(at: geojson) == .geojson)
        let (back, _) = try await bench.convert(geojson, from: .geojson, to: .gpx)
        #expect(FileFormat.detect(at: back) == .gpx)

        let final = try GeoXML.readGPX(Data(contentsOf: back))
        #expect(final == original)
        #expect(final.paths.first { $0.kind == .track }?.points[1].time == GeoTrack.parseTime("2024-05-01T08:00:05.250Z"))
    }

    @Test func gpxToCSVHasOneRowPerPoint() async throws {
        let bench = Workbench()
        let gpx = try bench.file("ride.gpx", Data(Self.gpx.utf8))
        let (csv, result) = try await bench.convert(gpx, from: .gpx, to: .csv)
        #expect(result.notes == [.tracksBecamePoints])
        let lines = try String(contentsOf: csv, encoding: .utf8).split(separator: "\r\n")
        #expect(lines.count == 9)
        #expect(lines[0] == "lat,lon,ele,time,name")
        #expect(lines[1] == "47.6062,-122.3321,56.2,2024-05-01T08:00:00Z,Start & café")
        #expect(lines[7] == "47.60635,-122.3319,13,2024-05-01T08:00:05.250Z,Morning ride")
    }

    @Test func kmzIsRead() async throws {
        let bench = Workbench()
        let (kml, _) = try GeoXML.writeKML(try GeoXML.readGPX(Data(Self.gpx.utf8)))
        _ = try bench.file("doc.kml", kml)
        let kmz = bench.directory.appendingPathComponent("trip.kmz")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        zip.arguments = ["--format", "zip", "-cf", kmz.path, "-C", bench.directory.path, "doc.kml"]
        try zip.run()
        zip.waitUntilExit()
        #expect(FileFormat.detect(at: kmz) == .kmz)
        let (gpx, _) = try await bench.convert(kmz, from: .kmz, to: .gpx)
        #expect(try GeoXML.readGPX(Data(contentsOf: gpx)) == GeoXML.readGPX(Data(Self.gpx.utf8)))
    }

    @Test func plainGeoJSONLinesBecomeTracks() throws {
        let json = #"{"type":"Feature","properties":{"name":"Line"},"geometry":{"type":"LineString","coordinates":[[10,20],[11,21,5]]}}"#
        let document = try GeoTrack.readGeoJSON(Data(json.utf8))
        #expect(document.paths == [GeoPath(kind: .track, name: "Line", segments: [[
            GeoPoint(latitude: 20, longitude: 10), GeoPoint(latitude: 21, longitude: 11, elevation: 5),
        ]])])
        let gpx = String(decoding: try GeoXML.writeGPX(document), as: UTF8.self)
        #expect(gpx.contains(#"<trkpt lat="21" lon="11"><ele>5</ele></trkpt>"#))
    }

    @Test func badCoordinatesAreRejected() {
        #expect(throws: GeoTrack.Failure.self) {
            _ = try GeoXML.readGPX(Data(#"<gpx><wpt lat="95" lon="0"/></gpx>"#.utf8))
        }
        #expect(throws: GeoTrack.Failure.self) { _ = try GeoXML.readGPX(Data("<gpx><wpt".utf8)) }
    }
}

@Suite("Text encoding")
struct TextEncodingTests {
    static func cf(_ encoding: CFStringEncodings) -> String.Encoding { TextRecoder.cf(encoding) }

    @Test("Legacy encodings are detected and decoded", arguments: [
        ("Café crème brûlée — “quoted” naïve façade, 5 €", String.Encoding.windowsCP1252),
        ("Grüße aus Köln, schöne Straße und Äpfel.", .isoLatin1),
        ("日本語のテキストです。こんにちは世界、ありがとう。", .shiftJIS),
        ("简体中文文本，你好世界，谢谢你的帮助。", cf(.GB_18030_2000)),
        ("简体中文文本，你好世界，谢谢你的帮助。", cf(.GBK_95)),
        ("繁體中文文字，你好世界，謝謝你的幫助。", cf(.big5)),
        ("한국어 텍스트입니다. 안녕하세요 세계, 감사합니다.", cf(.EUC_KR)),
        ("Русский текст. Привет, мир! Спасибо большое.", cf(.KOI8_R)),
        ("Русский текст. Привет, мир! Спасибо большое.", .windowsCP1251),
        ("Zażółć gęślą jaźń. Pchnąć w tę łódź jeża.", .isoLatin2),
        ("Ελληνικό κείμενο. Γεια σου κόσμε, καλημέρα.", cf(.isoLatinGreek)),
    ] as [(String, String.Encoding)])
    func detects(text: String, encoding: String.Encoding) throws {
        let data = try #require(text.data(using: encoding))
        let decoded = try TextRecoder.decode(data)
        #expect(decoded.text == text, "decoded as \(decoded.encodingName)")
        #expect(decoded.encodingName != "utf-8")
    }

    @Test("UTF-16 with and without a BOM", arguments: [
        String.Encoding.utf16LittleEndian, .utf16BigEndian,
    ])
    func utf16(encoding: String.Encoding) throws {
        let text = "Plain words, ünïcode and 日本語.\r\nSecond line."
        let bare = try #require(text.data(using: encoding))
        let bom: [UInt8] = encoding == .utf16LittleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]
        #expect(try TextRecoder.decode(bare).text == text)
        #expect(try TextRecoder.decode(Data(bom) + bare).text == text)
        #expect(FileFormat.detect(header: bare, fileExtension: "txt") == .txt)
    }

    @Test func recodeNormalisesLineEndingsAndDropsTheBOM() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("one\r\ntwo\rthree\n".utf8)
        let (lf, decoded) = try TextRecoder.recode(data, edits: TextEdits())
        #expect(String(decoding: lf, as: UTF8.self) == "one\ntwo\nthree\n")
        #expect(decoded.hadBOM)
        let (crlf, _) = try TextRecoder.recode(data, edits: TextEdits(lineEndings: .crlf))
        #expect(String(decoding: crlf, as: UTF8.self) == "one\r\ntwo\r\nthree\r\n")
        let latin = try #require("é".data(using: .isoLatin1))
        let (forced, _) = try TextRecoder.recode(latin, edits: TextEdits(encoding: "iso-8859-1"))
        #expect(String(decoding: forced, as: UTF8.self) == "é")
    }

    @Test func engineRewritesTextAsUTF8() async throws {
        let bench = Workbench()
        let text = "Ceci est un résumé — “déjà vu”.\r\n"
        let input = try bench.file("old.txt", try #require(text.data(using: .windowsCP1252)))
        let options = ConversionOptions(text: TextEdits())
        let (output, result) = try await bench.convert(input, from: .txt, to: .txt, options: options)
        #expect(try Data(contentsOf: output) == Data("Ceci est un résumé — “déjà vu”.\n".utf8))
        #expect(result.notes == [.textRecoded])

        await #expect(throws: ConversionError.self) { _ = try await bench.convert(input, from: .txt, to: .txt) }
    }
}
