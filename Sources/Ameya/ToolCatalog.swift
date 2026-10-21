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
    /// When set, the panel's options decide the suffix and folder-ness instead (e.g. the country
    /// in "photo (India passport).jpg").
    var suffixForOptions: ((ConversionOptions) -> String)?
    var folderForOptions: ((ConversionOptions) -> Bool)?

    func outputSuffix(for options: ConversionOptions) -> String { suffixForOptions?(options) ?? outputSuffix }
    func producesFolder(for options: ConversionOptions) -> Bool { folderForOptions?(options) ?? producesFolder }

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
        tools = Self.imageTools(writable: writable) + Self.passportTools(writable: writable) + Self.pdfTools()
            + Self.sizePresetTools(writable: writable) + Self.pdfToolbox() // SizePresets.swift, PDFToolbox
            + Self.privacyTools(writable: writable) // PrivacyTools.swift
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

    // MARK: Passport photos

    static func passportTools(writable: Set<FileFormat>) -> [Tool] {
        // A single photo (not icons, not PDFs) on a Mac that can write JPEG.
        let onePhoto: ([FileFormat]) -> Bool = { formats in
            formats.count == 1 && formats[0].family == .image && !formats[0].isIcon && formats[0] != .pdf
                && writable.contains(.jpeg)
        }
        var tool = Tool(
            id: "image.passportPhoto", title: "Passport photo…", systemImage: "person.crop.square",
            help: "Makes a passport or visa photo for the country you choose, with a plain background.",
            outputSuffix: "(passport photo)", isAvailable: onePhoto,
            makeRequest: { format in
                var options = ConversionOptions()
                options.passport = PassportPhotoOptions(spec: PassportPhotoPanel.defaultSpec)
                return ConversionRequest(source: format, target: .jpeg, options: options)
            },
            panel: { _, done in AnyView(PassportPhotoPanel(done: done)) }
        )
        tool.suffixForOptions = { options in
            guard let passport = options.passport else { return "(passport photo)" }
            let name = passport.spec.id == PassportSpec.customID ? "passport photo" : passport.spec.name
            return passport.printSheet ? "(\(name) print)" : "(\(name))"
        }
        tool.folderForOptions = { $0.passport?.printSheet ?? false }
        return [tool]
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

    // MARK: PDF toolbox and text recognition (panels in PDFPagePanels.swift and PDFToolPanels.swift)

    static func pdfToolbox() -> [Tool] {
        let allPDF: ([FileFormat]) -> Bool = { $0.allSatisfy { $0 == .pdf } }
        let onePDF: ([FileFormat]) -> Bool = { $0 == [.pdf] }
        func pdf(_ action: PDFAction) -> (FileFormat) -> ConversionRequest {
            { format in ConversionRequest(source: format, target: .pdf, options: ConversionOptions(pdf: action)) }
        }
        func panel<Content: View>(_ content: @escaping @MainActor (@escaping (PDFAction) -> Void) -> Content) -> Tool.Panel {
            { _, done in AnyView(content { action in done(ConversionOptions(pdf: action)) }) }
        }

        return [
            Tool(id: "pdf.searchable", title: "Make PDF searchable", systemImage: "text.viewfinder",
                 help: "Recognises the words on scanned pages so you can search, select and copy them. Pages that already have text stay as they are.",
                 outputSuffix: "(searchable)", isAvailable: allPDF,
                 makeRequest: pdf(.ocr(languages: nil))),
            Tool(id: "image.copyText", title: "Copy text from image", systemImage: "doc.text.viewfinder",
                 help: "Recognises the words in the picture and saves them as a text file.",
                 outputSuffix: "(text)",
                 isAvailable: { formats in formats.allSatisfy { $0.family == .image && !$0.isIcon } },
                 makeRequest: { format in
                     ConversionRequest(source: format, target: .txt, options: ConversionOptions(pdf: .ocr(languages: nil)))
                 }),
            Tool(id: "pdf.removePages", title: "Remove pages…", systemImage: "doc.badge.ellipsis",
                 help: "Choose pages to leave out of a copy of this PDF.",
                 outputSuffix: "(fewer pages)", isAvailable: onePDF, makeRequest: pdf(.deletePages([])),
                 panel: panel { done in PageGridPanel(mode: .remove, finish: done) }),
            Tool(id: "pdf.reorderPages", title: "Reorder pages…", systemImage: "arrow.up.arrow.down.square",
                 help: "Put the pages of this PDF in a new order.",
                 outputSuffix: "(reordered)", isAvailable: onePDF, makeRequest: pdf(.reorder([])),
                 panel: panel { done in PageGridPanel(mode: .reorder, finish: done) }),
            Tool(id: "pdf.extractPages", title: "Extract pages…", systemImage: "doc.on.clipboard",
                 help: "Makes a new PDF from the pages you choose, such as 1-3, 7.",
                 outputSuffix: "(extract)", isAvailable: onePDF, makeRequest: pdf(.reorder([])),
                 panel: panel { done in ExtractPagesPanel(finish: done) }),
            Tool(id: "pdf.pageNumbers", title: "Add page numbers…", systemImage: "number",
                 help: "Adds small page numbers at the bottom centre of every page.",
                 outputSuffix: "(numbered)", isAvailable: allPDF, makeRequest: pdf(.addPageNumbers(.number)),
                 panel: panel { done in PageNumbersPanel(finish: done) }),
            Tool(id: "pdf.watermark", title: "Watermark…", systemImage: "seal",
                 help: "Writes faint diagonal text, such as CONFIDENTIAL, across every page.",
                 outputSuffix: "(watermarked)", isAvailable: allPDF, makeRequest: pdf(.watermark(text: "", opacity: 0.25)),
                 panel: panel { done in WatermarkPanel(finish: done) }),
            Tool(id: "pdf.protect", title: "Password-protect PDF…", systemImage: "lock.doc",
                 help: "Makes a copy that needs a password to open.",
                 outputSuffix: "(protected)", isAvailable: allPDF, makeRequest: pdf(.protect(password: "")),
                 panel: panel { done in PasswordPanel(mode: .protect, finish: done) }),
            Tool(id: "pdf.removePassword", title: "Remove password…", systemImage: "lock.open",
                 help: "Makes a copy that opens without a password. You need the current password.",
                 outputSuffix: "(unlocked)", isAvailable: allPDF, makeRequest: pdf(.removePassword(password: "")),
                 panel: panel { done in PasswordPanel(mode: .remove, finish: done) }),
        ]
    }
}
