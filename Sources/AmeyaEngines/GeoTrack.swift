import AmeyaCore
import CArchive
import Foundation

/// GPS data shared by GPX, KML/KMZ and GeoJSON: waypoints, routes and tracks.
struct GeoPoint: Equatable {
    var latitude: Double
    var longitude: Double
    var elevation: Double?
    var time: Date?
    var name: String?
}

struct GeoPath: Equatable {
    enum Kind: String { case track, route }

    var kind: Kind
    var name: String?
    /// Tracks may be split into segments (e.g. where the GPS lost signal); routes have one.
    var segments: [[GeoPoint]]

    var points: [GeoPoint] { segments.flatMap { $0 } }
}

struct GeoDocument: Equatable {
    var waypoints: [GeoPoint] = []
    var paths: [GeoPath] = []

    var pointCount: Int { waypoints.count + paths.reduce(0) { $0 + $1.points.count } }
}

enum GeoTrack {
    static let maxPoints = 5_000_000

    enum Failure: LocalizedError {
        case invalid(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .invalid(let reason): "This GPS file couldn't be read: \(reason)."
            case .empty: "This file has no waypoints, routes or tracks."
            }
        }
    }

    // MARK: Routing

    static func read(_ data: Data, as format: FileFormat, input: URL) throws -> GeoDocument {
        let document: GeoDocument
        switch format {
        case .gpx: document = try GeoXML.readGPX(data)
        case .kml: document = try GeoXML.readKML(data)
        case .kmz: document = try GeoXML.readKML(try kmlInsideKMZ(input))
        case .geojson: document = try readGeoJSON(data)
        default: throw ConversionError.unsupportedConversion(from: format, to: .gpx)
        }
        guard document.pointCount > 0 else { throw Failure.empty }
        guard document.pointCount <= maxPoints else { throw Failure.invalid("it has more than \(maxPoints) points") }
        return document
    }

    static func write(_ document: GeoDocument, as format: FileFormat) throws -> (Data, [ConversionNote]) {
        switch format {
        case .gpx: return (try GeoXML.writeGPX(document), [])
        case .kml: return try GeoXML.writeKML(document)
        case .geojson: return (try writeGeoJSON(document), [])
        case .csv: return (csv(document), [.tracksBecamePoints])
        default: throw ConversionError.unsupportedTarget(format)
        }
    }

    // MARK: Times

    static func parseTime(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: trimmed) { return date }
        // Some devices omit the time zone; GPX times are UTC.
        return plain.date(from: trimmed + "Z")
    }

    static func formatTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        let wholeSeconds = date.timeIntervalSince1970.rounded(.down) == date.timeIntervalSince1970
        formatter.formatOptions = wholeSeconds ? [.withInternetDateTime] : [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// The shortest text that reads back as the same number.
    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : "\(value)"
    }

    // MARK: GeoJSON

    static func readGeoJSON(_ data: Data) throws -> GeoDocument {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Failure.invalid("it isn't valid JSON")
        }
        guard let root = object as? [String: Any] else { throw Failure.invalid("it isn't a GeoJSON object") }
        var document = GeoDocument()
        switch root["type"] as? String {
        case "FeatureCollection":
            for feature in root["features"] as? [[String: Any]] ?? [] { try addFeature(feature, to: &document) }
        case "Feature":
            try addFeature(root, to: &document)
        default:
            try addGeometry(root, properties: [:], to: &document)
        }
        return document
    }

    private static func addFeature(_ feature: [String: Any], to document: inout GeoDocument) throws {
        guard let geometry = feature["geometry"] as? [String: Any] else { return } // null geometry is allowed
        try addGeometry(geometry, properties: feature["properties"] as? [String: Any] ?? [:], to: &document)
    }

    private static func addGeometry(_ geometry: [String: Any], properties: [String: Any], to document: inout GeoDocument) throws {
        let name = properties["name"] as? String
        let kind = GeoPath.Kind(rawValue: properties["kind"] as? String ?? "") ?? .track
        // coordTimes (the convention used by togeojson) is a list, or a list per line.
        let times = properties["coordTimes"] as? [Any] ?? []
        func timeList(_ index: Int?) -> [String] {
            guard let index else { return times.compactMap { $0 as? String } }
            return index < times.count ? (times[index] as? [Any] ?? []).compactMap { $0 as? String } : []
        }
        func line(_ raw: Any?, times: [String]) throws -> [GeoPoint] {
            guard let positions = raw as? [Any] else { throw Failure.invalid("a line has no coordinates") }
            return try positions.enumerated().map { index, position in
                var point = try self.position(position)
                if index < times.count { point.time = parseTime(times[index]) }
                return point
            }
        }

        let coordinates = geometry["coordinates"]
        switch geometry["type"] as? String {
        case "Point":
            var point = try position(coordinates as Any)
            point.name = name
            point.time = (properties["time"] as? String).flatMap(parseTime)
            document.waypoints.append(point)
        case "MultiPoint":
            for position in coordinates as? [Any] ?? [] {
                var point = try self.position(position)
                point.name = name
                document.waypoints.append(point)
            }
        case "LineString":
            document.paths.append(GeoPath(kind: kind, name: name, segments: [try line(coordinates, times: timeList(nil))]))
        case "MultiLineString":
            let lines = try (coordinates as? [Any] ?? []).enumerated().map { try line($1, times: timeList($0)) }
            document.paths.append(GeoPath(kind: kind, name: name, segments: lines))
        case "Polygon":
            // The outer ring, as a closed track.
            let rings = coordinates as? [Any] ?? []
            if let outer = rings.first {
                document.paths.append(GeoPath(kind: kind, name: name, segments: [try line(outer, times: [])]))
            }
        case "GeometryCollection":
            for child in geometry["geometries"] as? [[String: Any]] ?? [] {
                try addGeometry(child, properties: properties, to: &document)
            }
        default:
            break // MultiPolygon and unknown types are not GPS data
        }
    }

    private static func position(_ raw: Any) throws -> GeoPoint {
        guard let values = raw as? [Any], values.count >= 2,
              let longitude = (values[0] as? NSNumber)?.doubleValue,
              let latitude = (values[1] as? NSNumber)?.doubleValue else {
            throw Failure.invalid("a position isn't [longitude, latitude]")
        }
        let elevation = values.count > 2 ? (values[2] as? NSNumber)?.doubleValue : nil
        return try validated(GeoPoint(latitude: latitude, longitude: longitude, elevation: elevation))
    }

    static func validated(_ point: GeoPoint) throws -> GeoPoint {
        guard (-90...90).contains(point.latitude), (-180...180).contains(point.longitude) else {
            throw Failure.invalid("a coordinate is out of range (\(point.latitude), \(point.longitude))")
        }
        return point
    }

    static func writeGeoJSON(_ document: GeoDocument) throws -> Data {
        func position(_ point: GeoPoint) -> [Double] {
            [point.longitude, point.latitude] + (point.elevation.map { [$0] } ?? [])
        }
        var features: [[String: Any]] = document.waypoints.map { point in
            var properties: [String: Any] = ["kind": "waypoint"]
            if let name = point.name { properties["name"] = name }
            if let time = point.time { properties["time"] = formatTime(time) }
            return ["type": "Feature", "properties": properties,
                    "geometry": ["type": "Point", "coordinates": position(point)]]
        }
        for path in document.paths {
            var properties: [String: Any] = ["kind": path.kind.rawValue]
            if let name = path.name { properties["name"] = name }
            let geometry: [String: Any]
            let hasTimes = path.points.contains { $0.time != nil }
            if path.segments.count == 1 {
                geometry = ["type": "LineString", "coordinates": path.segments[0].map(position)]
                if hasTimes { properties["coordTimes"] = path.segments[0].map { $0.time.map(formatTime) ?? "" } }
            } else {
                geometry = ["type": "MultiLineString", "coordinates": path.segments.map { $0.map(position) }]
                if hasTimes { properties["coordTimes"] = path.segments.map { $0.map { $0.time.map(formatTime) ?? "" } } }
            }
            features.append(["type": "Feature", "properties": properties, "geometry": geometry])
        }
        let collection: [String: Any] = ["type": "FeatureCollection", "features": features]
        return try JSONSerialization.data(withJSONObject: collection, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: CSV

    static func csv(_ document: GeoDocument) -> Data {
        var rows: [[String]] = [["lat", "lon", "ele", "time", "name"]]
        func row(_ point: GeoPoint, fallbackName: String?) -> [String] {
            [number(point.latitude), number(point.longitude), point.elevation.map(number) ?? "",
             point.time.map(formatTime) ?? "", point.name ?? fallbackName ?? ""]
        }
        rows += document.waypoints.map { row($0, fallbackName: nil) }
        for path in document.paths { rows += path.points.map { row($0, fallbackName: path.name) } }
        return DelimitedText.write(rows.map { $0.map(DataValue.string) }, delimiter: DelimitedText.comma)
    }

    // MARK: KMZ

    static let maxKMLBytes = 256 << 20

    /// The KML document inside a KMZ (a ZIP file): doc.kml, or else the first .kml at the top level.
    static func kmlInsideKMZ(_ url: URL) throws -> Data {
        guard let reader = archive_read_new() else { throw ConversionError.mediaFailed("libarchive unavailable") }
        defer { archive_read_free(reader) }
        archive_read_support_filter_all(reader)
        archive_read_support_format_all(reader)
        guard archive_read_open_filename(reader, url.path, 64 * 1024) == ARCHIVE_OK else { throw ConversionError.unreadable }

        var fallback: Data?
        var entry: OpaquePointer?
        while archive_read_next_header(reader, &entry) == ARCHIVE_OK, let entry {
            let path = (archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry)).map { String(cString: $0) } ?? ""
            let isKML = path.lowercased().hasSuffix(".kml") && archive_entry_is_encrypted(entry) == 0
            guard isKML, path == "doc.kml" || fallback == nil else {
                archive_read_data_skip(reader)
                continue
            }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let read = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                if read == 0 { break }
                guard read > 0 else { throw Failure.invalid("the KMZ archive is damaged") }
                data.append(contentsOf: buffer[0..<read])
                guard data.count <= maxKMLBytes else { throw Failure.invalid("the KML inside is larger than 256 MB") }
            }
            if path == "doc.kml" { return data }
            fallback = data
        }
        guard let fallback else { throw Failure.invalid("the KMZ file contains no KML document") }
        return fallback
    }
}
