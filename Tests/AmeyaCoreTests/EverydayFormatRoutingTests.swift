import Foundation
import Testing
@testable import AmeyaCore

@Suite("Everyday formats")
struct EverydayFormatRoutingTests {
    @Test func contentIdentifiesContactsAndTracks() {
        #expect(FileFormat.sniff(Data("BEGIN:VCARD\r\nVERSION:3.0".utf8)) == .vcf)
        #expect(FileFormat.sniff(Data("<?xml version=\"1.0\"?>\n<gpx version=\"1.1\">".utf8)) == .gpx)
        #expect(FileFormat.sniff(Data("<?xml version=\"1.0\"?><kml xmlns=\"http://www.opengis.net/kml/2.2\">".utf8)) == .kml)
        // A vCard with a misleading extension is still a vCard.
        #expect(FileFormat.detect(header: Data("begin:vcard\n".utf8), fileExtension: "txt") == .vcf)
    }

    @Test func geoJSONIsToldApartFromOtherJSON() {
        let collection = Data(#"{ "type": "FeatureCollection", "features": [] }"#.utf8)
        #expect(FileFormat.detect(header: collection, fileExtension: "json") == .geojson)
        #expect(FileFormat.detect(header: collection, fileExtension: "geojson") == .geojson)
        #expect(FileFormat.detect(header: Data(#"{"type":"Point","x":1}"#.utf8), fileExtension: "json") == .json)
        #expect(FileFormat.detect(header: Data(#"{"a":1}"#.utf8), fileExtension: "geojson") == .geojson)
    }

    @Test func kmzIsAZipWithItsOwnExtension() {
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00])
        #expect(FileFormat.detect(header: zip, fileExtension: "kmz") == .kmz)
        #expect(!FileFormat.systemWritable().contains(.kmz))
    }

    @Test func utf16WithoutBOMCountsAsText() {
        let utf16 = "plain text".data(using: .utf16LittleEndian)!
        #expect(FileFormat.detect(header: utf16, fileExtension: "txt") == .txt)
        #expect(FileFormat.detect(header: Data([0, 0, 0, 1, 0, 0, 2]), fileExtension: "txt") == nil)
    }

    @Test func routes() {
        let yes: [(FileFormat, FileFormat)] = [
            (.txt, .png), (.png, .txt), (.jpeg, .txt), (.heic, .txt), (.vcf, .csv), (.vcf, .json), (.csv, .vcf),
            (.gpx, .kml), (.gpx, .geojson), (.kml, .gpx), (.kmz, .gpx), (.kmz, .geojson), (.geojson, .gpx),
            (.gpx, .csv), (.geojson, .csv),
        ]
        let no: [(FileFormat, FileFormat)] = [(.md, .png), (.vcf, .xlsx), (.json, .vcf), (.gpx, .kmz), (.gpx, .json), (.txt, .txt)]
        for (source, target) in yes { #expect(ConversionMatrix.canConvert(from: source, to: target), "\(source) -> \(target)") }
        for (source, target) in no { #expect(!ConversionMatrix.canConvert(from: source, to: target), "\(source) -> \(target)") }
    }

    @Test func textCanBeRecodedOnlyWithEdits() throws {
        let edits = ConversionOptions(text: TextEdits())
        #expect(ConversionMatrix.canEdit(.txt, options: edits))
        #expect(ConversionMatrix.canEdit(.srt, options: edits))
        #expect(!ConversionMatrix.canEdit(.txt, options: ConversionOptions()))
        #expect(!ConversionMatrix.canEdit(.png, options: edits))
        let request = ConversionRequest(source: .txt, target: .txt, options: edits)
        #expect(try WorkerProtocol.decodeRequest(WorkerProtocol.encode(request)) == request)
    }

    @Test func possibleLosses() {
        let matrix = ConversionMatrix(writable: FileFormat.systemWritable())
        #expect(matrix.possibleLosses(from: .txt, to: .png) == [.madeQRCode])
        #expect(matrix.possibleLosses(from: .png, to: .txt) == [.onlyCodesRead])
        #expect(matrix.possibleLosses(from: .vcf, to: .csv) == [.contactFieldsLimited])
        #expect(matrix.possibleLosses(from: .gpx, to: .csv) == [.tracksBecamePoints])
        #expect(matrix.possibleLosses(from: .gpx, to: .kml).isEmpty)
    }
}
