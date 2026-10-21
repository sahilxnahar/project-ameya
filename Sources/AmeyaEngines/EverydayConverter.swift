import AmeyaCore
import Foundation

/// Everyday conversions: QR codes, contacts, GPS tracks and text re-encoding.
enum EverydayConverter {
    /// Whether this engine handles the pair (or the in-place edit, when source == target).
    static func handles(_ source: FileFormat, _ target: FileFormat, options: ConversionOptions) -> Bool {
        if source == target { return ConversionMatrix.canEdit(source, options: options) }
        switch (source.family, target.family) {
        case (.document, .image): return source == .txt && target == .png
        case (.image, .document): return target == .txt
        case (.contacts, _), (_, .contacts), (.geo, _): return true
        default: return false
        }
    }

    static func convert(input: URL, from source: FileFormat, request: ConversionRequest, output: URL,
                        progress: (Double) -> Void) throws -> [ConversionNote] {
        let target = request.target
        let data = try read(input)
        progress(0.2)
        var notes: [ConversionNote] = []
        let result: Data

        switch (source, target) {
        case _ where source == target:
            let (recoded, decoded) = try TextRecoder.recode(data, edits: request.options.text ?? TextEdits())
            result = recoded
            if decoded.encodingName.lowercased() != "utf-8" || decoded.hadBOM { notes.append(.textRecoded) }

        case (.txt, .png):
            result = try QRCode.png(for: try TextRecoder.text(from: data))
            notes.append(.madeQRCode)

        case (_, .txt) where source.family == .image:
            result = Data((try QRCode.decode(data, options: request.options).joined(separator: "\n") + "\n").utf8)
            notes.append(.onlyCodesRead)

        case (.vcf, .csv):
            result = VCard.csv(try VCard.parse(data))
            notes.append(.contactFieldsLimited)
        case (.vcf, .json):
            result = try VCard.json(try VCard.parse(data))
            notes.append(.contactFieldsLimited)
        case (.csv, .vcf):
            result = VCard.write(try VCard.contacts(fromCSV: data))

        case _ where source.family == .geo:
            let document = try GeoTrack.read(data, as: source, input: input)
            progress(0.6)
            (result, notes) = try GeoTrack.write(document, as: target)

        default:
            throw ConversionError.unsupportedConversion(from: source, to: target)
        }
        try result.write(to: output)
        progress(1)
        return notes
    }

    private static func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ConversionError.unreadable
        }
    }
}
