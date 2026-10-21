import AmeyaCore
import SwiftUI

/// Something to do with the dropped files besides a plain format change: "Remove location",
/// "Combine into one PDF", … Shown under "Tools" when `isAvailable` accepts the pending files.
///
/// To add a tool, add a `Tool` to one of the groups below or add your own group function and
/// list it in `ToolCatalog.init`. Everything runs locally in the sandboxed worker.
struct Tool: Identifiable {
    enum Mode {
        /// One job per file.
        case eachFile
        /// One job over all pending files, in the order they were added (e.g. merge).
        case allTogether
    }

    /// A settings panel shown in a sheet before the tool runs. Call `done` with the chosen options;
    /// they replace the options from `makeRequest`. The sheet itself provides Cancel.
    typealias Panel = @MainActor (_ formats: [FileFormat], _ done: @escaping (ConversionOptions) -> Void) -> AnyView

    /// Stable identifier, e.g. "image.removeLocation".
    let id: String
    /// Plain, friendly wording: "Make it smaller", not "Downsample".
    let title: String
    /// SF Symbol name.
    let systemImage: String
    /// One sentence for VoiceOver and the tooltip: what will happen.
    let help: String
    let mode: Mode
    /// Whether the tool applies to all of these formats (the pending files).
    let isAvailable: ([FileFormat]) -> Bool
    /// The request for a file of this format. For `.allTogether`, it is called with the first file's
    /// format; the store fills in `inputs` with every file's format.
    let makeRequest: (FileFormat) -> ConversionRequest
    /// Added to the output name, e.g. "(rotated)" → "photo (rotated).jpg".
    let outputSuffix: String
    /// The result is a folder of files ("report (pages)") rather than one file.
    let producesFolder: Bool
    var panel: Panel?

    init(
        id: String, title: String, systemImage: String, help: String, mode: Mode = .eachFile,
        outputSuffix: String, producesFolder: Bool = false,
        isAvailable: @escaping ([FileFormat]) -> Bool,
        makeRequest: @escaping (FileFormat) -> ConversionRequest,
        panel: Panel? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.help = help
        self.mode = mode
        self.outputSuffix = outputSuffix
        self.producesFolder = producesFolder
        self.isAvailable = isAvailable
        self.makeRequest = makeRequest
        self.panel = panel
    }
}

/// The registry of tools, built once for this Mac's encoders.
struct ToolCatalog {
    let tools: [Tool]

    init(writable: Set<FileFormat>) {
        tools = Self.imageTools(writable: writable) + Self.pdfTools()
            + Self.sizePresetTools(writable: writable) // SizePresets.swift
    }

    /// Tools offered for these files, in catalog order.
    func available(for formats: [FileFormat]) -> [Tool] {
        guard !formats.isEmpty else { return [] }
        return tools.filter { $0.isAvailable(formats) }
    }

    // MARK: Images

    static func imageTools(writable: Set<FileFormat>) -> [Tool] {
        /// Photos and pictures the edits make sense for (not icons).
        let editable: ([FileFormat]) -> Bool = { formats in
            formats.allSatisfy { $0.family == .image && !$0.isIcon }
                && formats.allSatisfy { writable.contains($0) || writable.contains(.jpeg) }
        }
        /// Keep the format when this Mac can write it; otherwise JPEG (e.g. Camera RAW).
        let keep: (FileFormat) -> FileFormat = { writable.contains($0) ? $0 : .jpeg }
        func edit(_ edits: ImageEdits, to target: ((FileFormat) -> FileFormat)? = nil) -> (FileFormat) -> ConversionRequest {
            { format in
                ConversionRequest(source: format, target: (target ?? keep)(format), options: ConversionOptions(image: edits))
            }
        }

        return [
            Tool(id: "image.removeLocation", title: "Remove location", systemImage: "location.slash",
                 help: "Makes a copy without the place where the photo was taken.",
                 outputSuffix: "(no location)", isAvailable: editable,
                 makeRequest: edit(ImageEdits(metadata: .removeLocation))),
            Tool(id: "image.removeMetadata", title: "Remove all hidden details", systemImage: "eye.slash",
                 help: "Makes a copy without location, camera and other hidden details.",
                 outputSuffix: "(no details)", isAvailable: editable,
                 makeRequest: edit(ImageEdits(metadata: .removeAll))),
            Tool(id: "image.rotateLeft", title: "Rotate left", systemImage: "rotate.left",
                 help: "Makes a copy turned a quarter turn to the left.",
                 outputSuffix: "(rotated)", isAvailable: editable,
                 makeRequest: edit(ImageEdits(rotation: 270))),
            Tool(id: "image.rotateRight", title: "Rotate right", systemImage: "rotate.right",
                 help: "Makes a copy turned a quarter turn to the right.",
                 outputSuffix: "(rotated)", isAvailable: editable,
                 makeRequest: edit(ImageEdits(rotation: 90))),
            Tool(id: "image.smaller", title: "Make it smaller", systemImage: "arrow.down.right.and.arrow.up.left",
                 help: "Makes a copy no wider or taller than 2048 pixels.",
                 outputSuffix: "(smaller)", isAvailable: editable,
                 makeRequest: edit(ImageEdits(maxPixelSize: 2048))),
        ]
    }

    // MARK: PDFs

    static func pdfTools() -> [Tool] {
        let allPDF: ([FileFormat]) -> Bool = { $0.allSatisfy { $0 == .pdf } }
        func pdf(_ action: PDFAction) -> (FileFormat) -> ConversionRequest {
            { format in ConversionRequest(source: format, target: .pdf, options: ConversionOptions(pdf: action)) }
        }

        return [
            Tool(id: "pdf.merge", title: "Combine into one PDF", systemImage: "doc.on.doc",
                 help: "Puts all these files, in this order, into one PDF. Pictures become pages.",
                 mode: .allTogether, outputSuffix: "(merged)",
                 isAvailable: { formats in
                     formats.count >= 2 && formats.allSatisfy { $0 == .pdf || ($0.family == .image && !$0.isIcon) }
                 },
                 makeRequest: pdf(.merge)),
            Tool(id: "pdf.split", title: "Split into pages", systemImage: "square.split.2x1",
                 help: "Makes a folder with one PDF for each page.",
                 outputSuffix: "(pages)", producesFolder: true, isAvailable: allPDF,
                 makeRequest: pdf(.splitEveryPage)),
            Tool(id: "pdf.rotate", title: "Rotate PDF pages", systemImage: "rotate.right",
                 help: "Makes a copy with every page turned a quarter turn to the right.",
                 outputSuffix: "(rotated)", isAvailable: allPDF,
                 makeRequest: pdf(.rotate(degrees: 90, pages: nil))),
        ]
    }
}
