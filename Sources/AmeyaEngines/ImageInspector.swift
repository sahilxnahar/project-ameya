import AmeyaCore
import Foundation
import ImageIO

/// Reads the hidden details of a photo: EXIF, GPS, TIFF, IPTC, maker notes and XMP (including
/// edit history). Only ImageIO's property parsers run; no pixels are decoded.
enum ImageInspector {
    typealias Finding = PrivacyReport.Finding

    static func inspect(_ url: URL) throws -> PrivacyReport {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw ConversionError.unreadable
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        var findings = findings(in: properties)
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil) {
            findings += xmpFindings(metadata, known: Set(findings.map(\.value)))
        }
        return PrivacyReport(kind: .photo, findings: findings, facts: facts(properties), canClean: true)
    }

    static func facts(_ properties: [CFString: Any]) -> PrivacyReport.Facts {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var width = properties[kCGImagePropertyPixelWidth] as? Int
        var height = properties[kCGImagePropertyPixelHeight] as? Int
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            swap(&width, &height) // shown turned a quarter, as every viewer does
        }
        let taken = (exif[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (tiff[kCGImagePropertyTIFFDateTime] as? String)
        return PrivacyReport.Facts(width: width, height: height, dateTaken: taken, camera: camera(tiff))
    }

    /// "Canon EOS R5", not "Canon Canon EOS R5".
    static func camera(_ tiff: [CFString: Any]) -> String? {
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if model.isEmpty { return make.isEmpty ? nil : make }
        let brand = make.lowercased().split(separator: " ").first.map(String.init) ?? ""
        if brand.isEmpty || model.lowercased().hasPrefix(brand) { return model }
        return "\(make) \(model)"
    }

    private static func findings(in properties: [CFString: Any]) -> [Finding] {
        var found: [Finding] = []
        func add(_ group: PrivacyReport.Group, _ label: String, _ value: Any?) {
            guard let text = describe(value), !text.isEmpty else { return }
            found.append(Finding(group: group, label: label, value: text))
        }
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        // Location: coordinates and time only. Turning them into a place name would need the internet.
        if let position = position(gps) { add(.location, "GPS position (latitude, longitude)", position) }
        if let altitude = gps[kCGImagePropertyGPSAltitude] as? Double {
            add(.location, "Height above sea level", String(format: "%.0f m", (gps[kCGImagePropertyGPSAltitudeRef] as? Int) == 1 ? -altitude : altitude))
        }
        if let date = gps[kCGImagePropertyGPSDateStamp] as? String {
            add(.location, "Time at that place", "\(date) \(gps[kCGImagePropertyGPSTimeStamp] as? String ?? "") UTC")
        }
        if gps[kCGImagePropertyGPSImgDirection] != nil { add(.location, "Direction the camera faced", "\(describe(gps[kCGImagePropertyGPSImgDirection]) ?? "")°") }
        add(.location, "City", iptc[kCGImagePropertyIPTCCity])
        add(.location, "Region", iptc[kCGImagePropertyIPTCProvinceState])
        add(.location, "Country", iptc[kCGImagePropertyIPTCCountryPrimaryLocationName])
        add(.location, "Place", iptc[kCGImagePropertyIPTCSubLocation])

        add(.name, "Camera owner", exif[kCGImagePropertyExifCameraOwnerName])
        add(.name, "Camera owner", aux[kCGImagePropertyExifAuxOwnerName])
        add(.name, "Artist", tiff[kCGImagePropertyTIFFArtist])
        add(.name, "Copyright", tiff[kCGImagePropertyTIFFCopyright])
        add(.name, "By", iptc[kCGImagePropertyIPTCByline])
        add(.name, "Copyright notice", iptc[kCGImagePropertyIPTCCopyrightNotice])
        add(.name, "Credit", iptc[kCGImagePropertyIPTCCredit])
        if let contact = iptc[kCGImagePropertyIPTCCreatorContactInfo] as? [CFString: Any] {
            add(.name, "Contact details", contact.values.compactMap(describe).joined(separator: ", "))
        }

        add(.device, "Camera", camera(tiff))
        add(.device, "Lens", exif[kCGImagePropertyExifLensModel] ?? aux[kCGImagePropertyExifAuxLensModel])
        add(.device, "Camera serial number", exif[kCGImagePropertyExifBodySerialNumber])
        add(.device, "Camera serial number", aux[kCGImagePropertyExifAuxSerialNumber])
        add(.device, "Lens serial number", exif[kCGImagePropertyExifLensSerialNumber] ?? aux[kCGImagePropertyExifAuxLensSerialNumber])
        add(.device, "Computer", tiff[kCGImagePropertyTIFFHostComputer])
        let makerNotes = properties.keys.map { $0 as String }.filter { $0.hasPrefix("{Maker") }
        if !makerNotes.isEmpty {
            add(.device, "Camera maker's private notes", "Present (can include serial numbers and settings)")
        }

        add(.edits, "Taken", exif[kCGImagePropertyExifDateTimeOriginal])
        add(.edits, "Last changed", tiff[kCGImagePropertyTIFFDateTime])
        add(.edits, "Made with", tiff[kCGImagePropertyTIFFSoftware])
        add(.edits, "Made with", iptc[kCGImagePropertyIPTCOriginatingProgram])

        add(.other, "Description", tiff[kCGImagePropertyTIFFImageDescription] ?? iptc[kCGImagePropertyIPTCCaptionAbstract])
        add(.other, "Title", iptc[kCGImagePropertyIPTCObjectName])
        add(.other, "Keywords", iptc[kCGImagePropertyIPTCKeywords])
        add(.other, "Comment", exif[kCGImagePropertyExifUserComment])
        add(.other, "Unique photo ID", exif[kCGImagePropertyExifImageUniqueID])
        return unique(found)
    }

    /// "51.50070, -0.12460", or nil without both coordinates.
    static func position(_ gps: [CFString: Any]) -> String? {
        guard let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
        let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
        return String(format: "%.5f, %.5f", south ? -latitude : latitude, west ? -longitude : longitude)
    }

    /// XMP that ImageIO doesn't map to the dictionaries above: edit history, editing apps, IDs.
    private static func xmpFindings(_ metadata: CGImageMetadata, known: Set<String>) -> [Finding] {
        guard let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return [] }
        var found: [Finding] = []
        for tag in tags.prefix(500) {
            let prefix = CGImageMetadataTagCopyPrefix(tag) as String? ?? ""
            let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
            let value = CGImageMetadataTagCopyValue(tag)
            let key = "\(prefix):\(name)"
            switch key {
            case "xmpMM:History", "photoshop:History":
                let steps = (value as? [Any])?.count ?? 1
                found.append(Finding(group: .edits, label: "Edit history", value: "\(steps) saved step\(steps == 1 ? "" : "s")"))
            case "xmp:CreatorTool": found.append(Finding(group: .edits, label: "Made with", value: text(value)))
            case "xmp:ModifyDate", "xmp:MetadataDate": found.append(Finding(group: .edits, label: "Last changed", value: text(value)))
            case "xmpMM:DerivedFrom": found.append(Finding(group: .edits, label: "Made from another file", value: "Yes"))
            case "dc:creator": found.append(Finding(group: .name, label: "Creator", value: text(value)))
            case "photoshop:AuthorsPosition": found.append(Finding(group: .name, label: "Job title", value: text(value)))
            case "aux:SerialNumber", "exifEX:BodySerialNumber":
                found.append(Finding(group: .device, label: "Camera serial number", value: text(value)))
            case "xmpMM:DocumentID", "xmpMM:OriginalDocumentID", "xmpMM:InstanceID":
                found.append(Finding(group: .other, label: "File ID that can link copies", value: text(value)))
            default:
                if prefix == "crs" {
                    if !found.contains(where: { $0.label == "Photo editing settings" }) {
                        found.append(Finding(group: .edits, label: "Photo editing settings", value: "Saved by a RAW editor"))
                    }
                }
            }
        }
        // ImageIO also exposes EXIF and IPTC as XMP; don't list the same value twice.
        return unique(found.filter { !known.contains($0.value) || $0.group == .edits && $0.label == "Edit history" })
    }

    private static func text(_ value: CFTypeRef?) -> String {
        if let array = value as? [Any] {
            return array.compactMap { item in
                let object = item as AnyObject
                return CFGetTypeID(object) == CGImageMetadataTagGetTypeID()
                    ? describe(CGImageMetadataTagCopyValue(object as! CGImageMetadataTag)) : describe(item)
            }.joined(separator: ", ")
        }
        if let dictionary = value as? [String: Any] { return dictionary.values.compactMap(describe).joined(separator: ", ") }
        return describe(value) ?? ""
    }

    static func describe(_ value: Any?) -> String? {
        switch value {
        case nil: return nil
        case let text as String: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber: return number.stringValue
        case let list as [Any]: return list.compactMap(describe).joined(separator: ", ")
        default: return String(describing: value!)
        }
    }

    private static func unique(_ findings: [Finding]) -> [Finding] {
        var seen: Set<String> = []
        return findings.filter { !$0.value.isEmpty && seen.insert("\($0.label)|\($0.value)").inserted }
    }
}
