import AmeyaCore
import SwiftUI

// MARK: Photo tools (panels in PhotoEditPanel, RedactPanel, PhotoStylePanels, PhotoMarkPanels)

extension ToolCatalog {
    static func photoTools(writable: Set<FileFormat>) -> [Tool] {
        /// Photos and pictures (not icons or PDFs) on a Mac that can write them, or JPEG instead.
        let pictures: ([FileFormat]) -> Bool = { formats in
            !formats.isEmpty && formats.allSatisfy { $0.family == .image && !$0.isIcon && $0 != .pdf }
                && formats.allSatisfy { writable.contains($0) || writable.contains(.jpeg) }
        }
        let onePicture: ([FileFormat]) -> Bool = { $0.count == 1 && pictures($0) }
        let keep: (FileFormat) -> FileFormat = { writable.contains($0) ? $0 : .jpeg }
        func request(_ edits: ImageEdits, to target: ((FileFormat) -> FileFormat)? = nil) -> (FileFormat) -> ConversionRequest {
            { format in ConversionRequest(source: format, target: (target ?? keep)(format), options: ConversionOptions(image: edits)) }
        }
        func panel<Content: View>(_ content: @escaping @MainActor (@escaping (ConversionOptions) -> Void) -> Content) -> Tool.Panel {
            { _, done in AnyView(content(done)) }
        }

        let edit = Tool(
            id: "image.editPhoto", title: "Edit photo…", systemImage: "slider.horizontal.3",
            help: "Brighten, warm up or sharpen a copy of the photo, with a live preview. Hold the preview to compare.",
            outputSuffix: "(edited)", isAvailable: onePicture,
            makeRequest: request(.photo(adjustments: PhotoAdjustments(autoEnhance: true))),
            panel: panel { done in PhotoEditPanel(done: done) })

        let redact = Tool(
            id: "image.redact", title: "Redact…", systemImage: "rectangle.dashed.badge.record",
            help: "Hide faces, names or number plates for good. Hidden details like location are removed too.",
            outputSuffix: "(redacted)", isAvailable: onePicture,
            makeRequest: request(.photo(redaction: Redaction(boxes: []), metadata: .removeAll)),
            panel: panel { done in RedactPanel(done: done) })

        let cutoutFormats = [FileFormat.png, .heic, .webp].filter(writable.contains)
        var removeBackground = Tool(
            id: "image.removeBackground", title: "Remove background", systemImage: "person.and.background.dotted",
            help: "Lifts the person, pet or object out of the photo and leaves a see-through background.",
            outputSuffix: "(no background)",
            isAvailable: { pictures($0) && writable.contains(.png) },
            makeRequest: request(.photo(removeBackground: BackgroundRemoval()), to: { _ in .png }),
            panel: panel { done in RemoveBackgroundPanel(done: done, writable: Set(cutoutFormats)) })
        removeBackground.targetForOptions = { options in
            options.image?.removeBackground?.format.flatMap { cutoutFormats.contains($0) ? $0 : nil } ?? .png
        }

        var beautify = Tool(
            id: "image.beautify", title: "Add background…", systemImage: "photo.artframe",
            help: "Puts the picture on a colourful background with rounded corners and a soft shadow. Great for screenshots.",
            outputSuffix: "(framed)", isAvailable: pictures,
            makeRequest: request(.photo(beautify: Beautify())),
            panel: panel { done in BeautifyPanel(done: done) })
        // Rounded corners on a clear backdrop need transparency.
        beautify.targetForOptions = { options in
            options.image?.beautify?.backdrop == .transparent && writable.contains(.png) ? .png : nil
        }

        var watermark = Tool(
            id: "image.watermark", title: "Watermark…", systemImage: "c.circle",
            help: "Adds your name or logo to every picture, where you choose and as faint as you like.",
            outputSuffix: "(watermarked)", isAvailable: pictures,
            makeRequest: request(.photo(watermark: Watermark(text: "©"))),
            panel: panel { done in ImageWatermarkPanel(done: done) })
        watermark.extraInputs = { options in
            guard options.image?.watermark?.useLogo == true, let logo = WatermarkLogo.url else { return [] }
            return [(logo, .png)]
        }

        let annotate = Tool(
            id: "image.annotate", title: "Annotate…", systemImage: "pencil.tip.crop.circle",
            help: "Draw arrows, boxes, text, numbered steps and highlights on a copy.",
            outputSuffix: "(annotated)", isAvailable: onePicture,
            makeRequest: request(.photo(annotations: [])),
            panel: panel { done in AnnotatePanel(done: done) })

        return [edit, redact, removeBackground, beautify, watermark, annotate]
    }
}
