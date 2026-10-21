import AmeyaCore
import Foundation
import ImageIO

/// Writes new details into a copy of a photo. Where ImageIO can (JPEG, PNG, TIFF, PSD and some
/// HEIC), the compressed picture is copied untouched and only the metadata changes; otherwise the
/// picture is re-saved and the result says so.
enum PhotoDetailsWriter {
    static func write(_ edit: PhotoDetailsEdit, input: URL, output: URL, target: FileFormat) throws -> [ConversionNote] {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let sourceType = CGImageSourceGetType(source) else {
            throw ConversionError.unreadable
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil).flatMap { CGImageMetadataCreateMutableCopy($0) }
            ?? CGImageMetadataCreateMutable()
        try apply(edit, to: metadata, properties: properties)

        let targetType = target.typeIdentifier as CFString
        if (targetType as String) == (sourceType as String), CGImageSourceGetCount(source) == 1,
           let destination = CGImageDestinationCreateWithURL(output as CFURL, sourceType, 1, nil) {
            let options: [CFString: Any] = [
                kCGImageDestinationMetadata: metadata,
                kCGImageDestinationMergeMetadata: false,
            ]
            var error: Unmanaged<CFError>?
            if CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) {
                return [.photoDetailsUpdated]
            }
            try? FileManager.default.removeItem(at: output)
        }

        // Re-save the picture with the new details.
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, targetType, 1, nil) else {
            throw ConversionError.unsupportedTarget(target)
        }
        let decode: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(properties[kCGImagePropertyPixelWidth] as? Int ?? 1,
                                                     properties[kCGImagePropertyPixelHeight] as? Int ?? 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, decode as CFDictionary) else {
            throw ConversionError.unreadable
        }
        // The orientation is now in the pixels.
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1 as CFNumber)
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodeFailed(target) }
        return [.photoDetailsReencoded]
    }

    /// Applies the edit to XMP-backed metadata, which ImageIO writes to EXIF, IPTC and XMP alike.
    static func apply(_ edit: PhotoDetailsEdit, to metadata: CGMutableImageMetadata, properties: [CFString: Any]) throws {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let dates: [(CFString, CFString, String?)] = [
            (kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, exif[kCGImagePropertyExifDateTimeOriginal] as? String),
            (kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeDigitized, exif[kCGImagePropertyExifDateTimeDigitized] as? String),
            (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFDateTime, tiff[kCGImagePropertyTIFFDateTime] as? String),
        ]
        switch edit.date {
        case .keep:
            break
        case .set(let text):
            guard let date = ExifDate.parse(text) else { throw ConversionError.invalidData("the new date isn't a date") }
            let value = ExifDate.string(from: date)
            for (dictionary, key, existing) in dates where existing != nil || key != kCGImagePropertyTIFFDateTime {
                set(metadata, dictionary, key, value as CFString)
            }
        case .shift(let hours):
            for (dictionary, key, existing) in dates {
                if let existing, let moved = ExifDate.shifted(existing, byHours: hours) {
                    set(metadata, dictionary, key, moved as CFString)
                }
            }
        }

        func text(_ value: String?, _ pairs: [(CFString, CFString)], xmp: [String]) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                xmp.forEach { CGImageMetadataRemoveTagWithPath(metadata, nil, $0 as CFString) }
            } else {
                pairs.forEach { set(metadata, $0.0, $0.1, trimmed as CFString) }
            }
        }
        text(edit.title, [(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCObjectName)], xmp: ["dc:title", "photoshop:Headline"])
        text(edit.description, [(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription),
                                (kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract)],
             xmp: ["dc:description", "tiff:ImageDescription", "exif:UserComment"])
        text(edit.author, [(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist),
                           (kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCByline)],
             xmp: ["dc:creator", "tiff:Artist"])
        text(edit.copyright, [(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFCopyright),
                              (kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCopyrightNotice)],
             xmp: ["dc:rights", "tiff:Copyright"])
        if let keywords = edit.keywords {
            let cleaned = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if cleaned.isEmpty {
                CGImageMetadataRemoveTagWithPath(metadata, nil, "dc:subject" as CFString)
            } else {
                set(metadata, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCKeywords, cleaned as CFArray)
            }
        }
    }

    private static func set(_ metadata: CGMutableImageMetadata, _ dictionary: CFString, _ key: CFString, _ value: CFTypeRef) {
        CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key, value)
    }
}
