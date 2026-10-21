import AmeyaCore
import Foundation

/// GPX 1.0/1.1 and KML 2.2 (including Google's gx:Track for timed tracks), read with XMLParser.
/// Element names are matched without their namespace prefix.
enum GeoXML {
    // MARK: Reading

    static func readGPX(_ data: Data) throws -> GeoDocument {
        let reader = GPXReader()
        try parse(data, with: reader, format: "GPX")
        if let error = reader.error { throw error }
        return reader.document
    }

    static func readKML(_ data: Data) throws -> GeoDocument {
        let reader = KMLReader()
        try parse(data, with: reader, format: "KML")
        if let error = reader.error { throw error }
        return reader.document
    }

    private static func parse(_ data: Data, with delegate: XMLParserDelegate, format: String) throws {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false // no network, no XXE
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "the XML is malformed"
            throw GeoTrack.Failure.invalid("it isn't valid \(format) (\(reason))")
        }
    }

    /// Checks that written XML reads back.
    private static func validate(_ data: Data, format: FileFormat) throws {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw ConversionError.encodeFailed(format) }
    }

    // MARK: Writing

    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            // Control characters other than tab and line breaks aren't allowed in XML 1.0.
            case _ where scalar.value < 0x20 && ![0x09, 0x0A, 0x0D].contains(scalar.value): break
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func writeGPX(_ document: GeoDocument) throws -> Data {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Ameya" xmlns="http://www.topografix.com/GPX/1/1">

        """
        func point(_ tag: String, _ point: GeoPoint, indent: String) {
            out += "\(indent)<\(tag) lat=\"\(GeoTrack.number(point.latitude))\" lon=\"\(GeoTrack.number(point.longitude))\">"
            if let elevation = point.elevation { out += "<ele>\(GeoTrack.number(elevation))</ele>" }
            if let time = point.time { out += "<time>\(GeoTrack.formatTime(time))</time>" }
            if let name = point.name { out += "<name>\(escape(name))</name>" }
            out += "</\(tag)>\n"
        }
        for waypoint in document.waypoints { point("wpt", waypoint, indent: "  ") }
        for path in document.paths where path.kind == .route {
            out += "  <rte>\n"
            if let name = path.name { out += "    <name>\(escape(name))</name>\n" }
            for routePoint in path.points { point("rtept", routePoint, indent: "    ") }
            out += "  </rte>\n"
        }
        for path in document.paths where path.kind == .track {
            out += "  <trk>\n"
            if let name = path.name { out += "    <name>\(escape(name))</name>\n" }
            for segment in path.segments {
                out += "    <trkseg>\n"
                for trackPoint in segment { point("trkpt", trackPoint, indent: "      ") }
                out += "    </trkseg>\n"
            }
            out += "  </trk>\n"
        }
        out += "</gpx>\n"
        let data = Data(out.utf8)
        try validate(data, format: .gpx)
        return data
    }

    static func writeKML(_ document: GeoDocument) throws -> (Data, [ConversionNote]) {
        var notes: [ConversionNote] = []
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">
        <Document>

        """
        func coordinate(_ point: GeoPoint, separator: String) -> String {
            ([point.longitude, point.latitude] + (point.elevation.map { [$0] } ?? []))
                .map(GeoTrack.number).joined(separator: separator)
        }
        func header(_ name: String?, kind: String) {
            out += "  <Placemark>\n"
            if let name { out += "    <name>\(escape(name))</name>\n" }
            out += "    <ExtendedData><Data name=\"kind\"><value>\(kind)</value></Data></ExtendedData>\n"
        }
        for waypoint in document.waypoints {
            header(waypoint.name, kind: "waypoint")
            if let time = waypoint.time { out += "    <TimeStamp><when>\(GeoTrack.formatTime(time))</when></TimeStamp>\n" }
            out += "    <Point><coordinates>\(coordinate(waypoint, separator: ","))</coordinates></Point>\n"
            out += "  </Placemark>\n"
        }
        for path in document.paths {
            header(path.name, kind: path.kind.rawValue)
            let timed = path.points.allSatisfy { $0.time != nil }
            if !timed && path.points.contains(where: { $0.time != nil }) { notes.append(.trackTimesRemoved) }
            if timed {
                // gx:Track keeps a time for every point.
                out += "    <gx:MultiTrack>\n"
                for segment in path.segments {
                    out += "      <gx:Track>\n"
                    for point in segment { out += "        <when>\(GeoTrack.formatTime(point.time!))</when>\n" }
                    for point in segment { out += "        <gx:coord>\(coordinate(point, separator: " "))</gx:coord>\n" }
                    out += "      </gx:Track>\n"
                }
                out += "    </gx:MultiTrack>\n"
            } else {
                out += "    <MultiGeometry>\n"
                for segment in path.segments {
                    let coordinates = segment.map { coordinate($0, separator: ",") }.joined(separator: " ")
                    out += "      <LineString><coordinates>\(coordinates)</coordinates></LineString>\n"
                }
                out += "    </MultiGeometry>\n"
            }
            out += "  </Placemark>\n"
        }
        out += "</Document>\n</kml>\n"
        let data = Data(out.utf8)
        try validate(data, format: .kml)
        return (data, notes)
    }
}

// MARK: - GPX

private final class GPXReader: NSObject, XMLParserDelegate {
    var document = GeoDocument()
    var error: Error?
    private var point: GeoPoint?
    private var path: GeoPath?
    private var segment: [GeoPoint] = []
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "wpt", "rtept", "trkpt":
            guard let latitude = attributes["lat"].flatMap(Double.init), let longitude = attributes["lon"].flatMap(Double.init) else {
                fail(parser, GeoTrack.Failure.invalid("a point has no valid lat/lon"))
                return
            }
            do {
                point = try GeoTrack.validated(GeoPoint(latitude: latitude, longitude: longitude))
            } catch {
                fail(parser, error)
            }
        case "trk": path = GeoPath(kind: .track, segments: [])
        case "rte": path = GeoPath(kind: .route, segments: []); segment = []
        case "trkseg": segment = []
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "ele": point?.elevation = Double(value)
        case "time": if point != nil { point?.time = GeoTrack.parseTime(value) }
        case "name":
            if point != nil { point?.name = value } else if path != nil { path?.name = value }
        case "wpt":
            if let point { document.waypoints.append(point) }
            point = nil
        case "rtept", "trkpt":
            if let point { segment.append(point) }
            point = nil
        case "trkseg":
            if !segment.isEmpty { path?.segments.append(segment) }
            segment = []
        case "rte":
            if !segment.isEmpty { path?.segments = [segment] }
            fallthrough
        case "trk":
            if let path, !path.points.isEmpty { document.paths.append(path) }
            path = nil
            segment = []
        default: break
        }
        text = ""
    }

    private func fail(_ parser: XMLParser, _ error: Error) {
        self.error = error
        parser.abortParsing()
    }
}

// MARK: - KML

private final class KMLReader: NSObject, XMLParserDelegate {
    var document = GeoDocument()
    var error: Error?
    private var stack: [String] = []
    private var text = ""
    private var inPlacemark = false
    private var name: String?
    private var kind: String?
    private var dataName: String?
    private var stampTime: Date?
    private var points: [GeoPoint] = []
    private var segments: [[GeoPoint]] = []
    private var whens: [Date?] = []
    private var coords: [GeoPoint] = []

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        stack.append(element)
        text = ""
        switch element {
        case "Placemark":
            inPlacemark = true
            (name, kind, stampTime, points, segments) = (nil, nil, nil, [], [])
        case "Track": (whens, coords) = ([], [])
        case "Data": dataName = attributes["name"]
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        stack.removeLast()
        let parent = stack.last
        guard inPlacemark else { text = ""; return }
        do {
            switch element {
            case "name" where parent == "Placemark": name = value
            case "value" where parent == "Data" && dataName == "kind": kind = value
            case "when" where parent == "Track": whens.append(GeoTrack.parseTime(value))
            case "when" where parent == "TimeStamp": stampTime = GeoTrack.parseTime(value)
            case "coord" where parent == "Track": coords.append(try point(value.split(whereSeparator: \.isWhitespace)))
            case "coordinates":
                let tuples = try value.split(whereSeparator: \.isWhitespace).map { try point($0.split(separator: ",")) }
                if parent == "Point" { points += tuples } else if !tuples.isEmpty { segments.append(tuples) }
            case "Track":
                for index in coords.indices where index < whens.count { coords[index].time = whens[index] }
                if !coords.isEmpty { segments.append(coords) }
            case "Placemark":
                inPlacemark = false
                for var point in points {
                    point.name = name
                    point.time = stampTime
                    document.waypoints.append(point)
                }
                if !segments.isEmpty {
                    let pathKind = GeoPath.Kind(rawValue: kind ?? "") ?? .track
                    document.paths.append(GeoPath(kind: pathKind, name: name, segments: pathKind == .route ? [segments.flatMap { $0 }] : segments))
                }
            default: break
            }
        } catch {
            self.error = error
            parser.abortParsing()
        }
        text = ""
    }

    private func point<S: StringProtocol>(_ parts: [S]) throws -> GeoPoint {
        guard parts.count >= 2, let longitude = Double(parts[0]), let latitude = Double(parts[1]) else {
            throw GeoTrack.Failure.invalid("a coordinate isn't \"longitude,latitude\"")
        }
        let elevation = parts.count > 2 ? Double(parts[2]) : nil
        return try GeoTrack.validated(GeoPoint(latitude: latitude, longitude: longitude, elevation: elevation))
    }
}
