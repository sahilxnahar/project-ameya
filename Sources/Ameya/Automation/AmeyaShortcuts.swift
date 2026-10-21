import AmeyaCore
import AppIntents

// Ready-made shortcuts for the most common jobs. They appear in the Shortcuts app and Spotlight
// without any setup, and Siri understands their phrases. Each asks for files when it runs.

struct ConvertToJPEGIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert to JPEG"
    static let description = IntentDescription("Makes JPEG copies of pictures, on this Mac.", categoryName: "Convert")

    @Parameter(title: "Pictures", supportedTypeIdentifiers: ["public.image", "com.adobe.pdf"])
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary { Summary("Convert \(\.$files) to JPEG") }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try await IntentRunner.convert(files, to: .jpeg))
    }
}

struct MakeSmallerIntent: AppIntent {
    static let title: LocalizedStringResource = "Make Pictures Smaller"
    static let description = IntentDescription("Makes copies of pictures no wider or taller than 2048 pixels.", categoryName: "Tools")

    @Parameter(title: "Pictures", supportedTypeIdentifiers: ["public.image"])
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary { Summary("Make \(\.$files) smaller") }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try await IntentRunner.run(toolID: "image.smaller", on: files))
    }
}

struct CombineIntoPDFIntent: AppIntent {
    static let title: LocalizedStringResource = "Combine into One PDF"
    static let description = IntentDescription("Puts PDFs and pictures, in order, into one PDF.", categoryName: "Tools")

    @Parameter(title: "Files", supportedTypeIdentifiers: ["com.adobe.pdf", "public.image"])
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary { Summary("Combine \(\.$files) into one PDF") }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try await IntentRunner.run(toolID: "pdf.merge", on: files))
    }
}

struct AmeyaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConvertToJPEGIntent(),
            phrases: ["Convert to JPEG with \(.applicationName)", "Make a JPEG with \(.applicationName)"],
            shortTitle: "Convert to JPEG",
            systemImageName: "photo"
        )
        AppShortcut(
            intent: MakeSmallerIntent(),
            phrases: ["Make it smaller with \(.applicationName)", "Shrink pictures with \(.applicationName)"],
            shortTitle: "Make It Smaller",
            systemImageName: "arrow.down.right.and.arrow.up.left"
        )
        AppShortcut(
            intent: CombineIntoPDFIntent(),
            phrases: ["Combine into PDF with \(.applicationName)", "Make one PDF with \(.applicationName)"],
            shortTitle: "Combine into PDF",
            systemImageName: "doc.on.doc"
        )
    }
}
