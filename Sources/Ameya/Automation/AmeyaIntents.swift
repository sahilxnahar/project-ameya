import AmeyaCore
import AppIntents
import Foundation
import UniformTypeIdentifiers

// Shortcuts actions. They run the same sandboxed worker as the window (via AutomationRunner),
// save into the folder chosen in Settings, and hand the new files back so a shortcut can
// pass them on to the next action.

// MARK: Formats

/// A format this Mac can write. An entity rather than an `AppEnum`: an enum's cases are fixed
/// when the app is built, but which formats are writable depends on this Mac (ImageIO's encoders,
/// the FFmpeg helper), so the list is made when Shortcuts asks for it.
struct FormatEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "File Format"
    static let defaultQuery = FormatQuery()

    /// `FileFormat.rawValue`, e.g. "jpeg".
    let id: String

    init(_ format: FileFormat) { id = format.rawValue }

    var format: FileFormat? { FileFormat(rawValue: id) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(format?.displayName ?? id)")
    }

    /// Every format this Mac can write, in Ameya's usual order.
    static func writable(_ writable: Set<FileFormat> = FileFormat.systemWritable()) -> [FormatEntity] {
        FileFormat.allCases
            .filter { writable.contains($0) && $0 != .other && $0 != .decompressed }
            .map(FormatEntity.init)
    }
}

struct FormatQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [FormatEntity] {
        let all = FormatEntity.writable()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [FormatEntity] {
        let all = FormatEntity.writable()
        if let named = FileFormat.named(string), let match = all.first(where: { $0.id == named.rawValue }) { return [match] }
        return all.filter { ($0.format?.displayName ?? $0.id).localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [FormatEntity] { FormatEntity.writable() }
}

// MARK: Tools

/// A tool from the catalog that needs no choices (no panel), such as "Make it smaller".
struct ToolEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Ameya Tool"
    static let defaultQuery = ToolQuery()

    /// `Tool.id`, e.g. "image.smaller".
    let id: String
    let title: String
    let help: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(help)")
    }

    static func all(_ writable: Set<FileFormat> = FileFormat.systemWritable()) -> [ToolEntity] {
        ToolCatalog(writable: writable).tools
            .filter { $0.panel == nil }
            .map { ToolEntity(id: $0.id, title: $0.title, help: $0.help) }
    }
}

struct ToolQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ToolEntity] {
        let all = ToolEntity.all()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [ToolEntity] {
        ToolEntity.all().filter { $0.title.localizedCaseInsensitiveContains(string) || $0.id.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [ToolEntity] { ToolEntity.all() }
}

// MARK: Actions

struct ConvertFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Files"
    static let description = IntentDescription(
        "Converts files to another format on this Mac. Nothing is uploaded, and your originals stay as they are.",
        categoryName: "Convert"
    )

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"])
    var files: [IntentFile]

    @Parameter(title: "Format")
    var format: FormatEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) to \(\.$format)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        guard let target = format.format else { throw IntentProblem("Ameya doesn't know the format \(format.id).") }
        return .result(value: try await IntentRunner.convert(files, to: target))
    }
}

struct RunToolIntent: AppIntent {
    static let title: LocalizedStringResource = "Use an Ameya Tool"
    static let description = IntentDescription(
        "Runs one of Ameya's tools, like Make it smaller or Combine into one PDF, on this Mac.",
        categoryName: "Tools"
    )

    @Parameter(title: "Tool")
    var tool: ToolEntity

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"])
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$tool) on \(\.$files)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try await IntentRunner.run(toolID: tool.id, on: files))
    }
}

// MARK: Running

/// A problem, in plain words, as Shortcuts shows it.
struct IntentProblem: Error, CustomLocalizedStringResourceConvertible, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var localizedStringResource: LocalizedStringResource { "\(message)" }
    var errorDescription: String? { message }
}

enum IntentRunner {
    typealias Plan = (AutomationRunner, [URL], URL) throws -> (jobs: [AutomationRunner.PlannedJob], skipped: [AutomationRunner.Skipped])

    static func convert(_ files: [IntentFile], to target: FileFormat) async throws -> [IntentFile] {
        try await perform(files) { runner, urls, directory in runner.planConversion(urls, to: target, in: directory) }
    }

    static func run(toolID: String, on files: [IntentFile]) async throws -> [IntentFile] {
        try await perform(files) { runner, urls, directory in
            guard let tool = runner.tool(id: toolID) else { throw AutomationRunner.Failure.unknownTool(toolID) }
            return try runner.planTool(tool, on: urls, in: directory)
        }
    }

    private static func perform(_ files: [IntentFile], plan: Plan) async throws -> [IntentFile] {
        guard let worker = Bundle.main.url(forAuxiliaryExecutable: "AmeyaWorker") else {
            throw IntentProblem("The converter is missing from Ameya. Reinstall the app.")
        }
        let directory = await MainActor.run {
            OutputLocation.directory(default: JobStore.realDownloadsDirectory().appendingPathComponent("Ameya", isDirectory: true))
        }
        let staged = try Staging(files)
        defer { staged.finish() }
        let outputs = try await run(staged.urls, worker: worker, directory: directory, plan: plan)
        return outputs.map { url in
            IntentFile(fileURL: url, filename: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension))
        }
    }

    /// Plans and runs the jobs; returns every file written. Throws when nothing could be made.
    static func run(_ urls: [URL], worker: URL, directory: URL, plan: Plan) async throws -> [URL] {
        guard !urls.isEmpty else { throw IntentProblem(AutomationRunner.Failure.noFiles.errorDescription!) }
        let runner = AutomationRunner(worker: worker)
        let planned: (jobs: [AutomationRunner.PlannedJob], skipped: [AutomationRunner.Skipped])
        do {
            planned = try plan(runner, urls, directory)
        } catch {
            throw IntentProblem((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        guard !planned.jobs.isEmpty else {
            throw IntentProblem(planned.skipped.map(\.reason).joined(separator: " ").nonEmpty ?? "There was nothing to do.")
        }
        if let job = planned.jobs.first(where: { $0.formats.count == 1 && ConversionMatrix.isTranscription(from: $0.formats[0], to: $0.request.target) }),
           let problem = await SpeechSetup.prepare(language: job.request.options.language) {
            throw IntentProblem(problem)
        }
        let outcomes = await runner.run(planned.jobs, in: directory)
        let written = outcomes.flatMap(\.files)
        guard !written.isEmpty else {
            throw IntentProblem(outcomes.compactMap(\.error).first ?? "Nothing was made.")
        }
        return written
    }

    /// Turns Shortcuts' files into readable file URLs: the original when Ameya may read it,
    /// otherwise a copy in a private temporary folder that is removed afterwards.
    private struct Staging {
        let urls: [URL]
        private let folder: URL
        private let scoped: [URL]

        init(_ files: [IntentFile]) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-shortcut-\(UUID().uuidString)", isDirectory: true)
            var urls: [URL] = []
            var scoped: [URL] = []
            for (index, file) in files.enumerated() {
                if let url = file.fileURL {
                    let started = url.startAccessingSecurityScopedResource()
                    if FileManager.default.isReadableFile(atPath: url.path) {
                        if started { scoped.append(url) }
                        urls.append(url)
                        continue
                    }
                    if started { url.stopAccessingSecurityScopedResource() }
                }
                // One subfolder per file keeps its name (outputs are named after it) even when two match.
                let slot = folder.appendingPathComponent("\(index)", isDirectory: true)
                try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
                var name = file.filename.replacingOccurrences(of: "/", with: "-")
                if name.isEmpty || name.hasPrefix(".") { name = "File \(index + 1)" + (name.hasPrefix(".") ? name : "") }
                let copy = slot.appendingPathComponent(name)
                try file.data.write(to: copy, options: .withoutOverwriting)
                urls.append(copy)
            }
            self.urls = urls
            self.scoped = scoped
        }

        func finish() {
            scoped.forEach { $0.stopAccessingSecurityScopedResource() }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
