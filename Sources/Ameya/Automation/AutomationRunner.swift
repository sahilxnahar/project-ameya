import AmeyaCore
import Foundation

/// Runs conversions and tools without the window: for Shortcuts (AmeyaIntents.swift) and the
/// `ameya` command-line tool (CommandLineTool.swift).
///
/// It plans jobs exactly like `JobStore` (same matrix, same tool catalog, same never-overwrite
/// names) and runs each one in its own sandboxed worker through `WorkerRunner`. It only reads the
/// inputs and only writes inside `directory`.
struct AutomationRunner {
    struct Outcome: Sendable {
        let inputs: [URL]
        /// The file or folder written, when the job succeeded.
        let output: URL?
        /// The files written: `output` itself, or the files inside an output folder.
        let files: [URL]
        let result: ConversionResult?
        let error: String?
    }

    /// A file left out before anything ran.
    struct Skipped: Sendable, Equatable {
        let input: URL
        let reason: String
    }

    enum Failure: Error, LocalizedError, Equatable {
        case noFiles
        case unknownFormat(String)
        case unknownTool(String)
        case toolNeedsApp(String)
        case nothingSuitable(String)

        var errorDescription: String? {
            switch self {
            case .noFiles: "There are no files to work on."
            case .unknownFormat(let name): "Ameya doesn't know a format called \"\(name)\"."
            case .unknownTool(let id): "Ameya doesn't have a tool called \"\(id)\"."
            case .toolNeedsApp(let title): "\"\(title)\" needs choices made in the Ameya window, so it can't run here."
            case .nothingSuitable(let detail): detail
            }
        }
    }

    let worker: URL
    let matrix: ConversionMatrix
    let catalog: ToolCatalog

    init(worker: URL, writable: Set<FileFormat> = FileFormat.systemWritable()) {
        self.worker = worker
        matrix = ConversionMatrix(writable: writable)
        catalog = ToolCatalog(writable: writable)
    }

    /// Tools that run without a panel, in catalog order.
    var automatableTools: [Tool] { catalog.tools.filter { $0.panel == nil } }

    func tool(id: String) -> Tool? { catalog.tools.first { $0.id == id } }

    /// Detects each file's format. Missing, folder and empty files are skipped with a reason.
    static func detect(_ urls: [URL]) -> (files: [(URL, FileFormat)], skipped: [Skipped]) {
        var files: [(URL, FileFormat)] = []
        var skipped: [Skipped] = []
        for url in urls {
            var isFolder: ObjCBool = false
            if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) {
                skipped.append(Skipped(input: url, reason: "There's no file called \(url.lastPathComponent)."))
            } else if isFolder.boolValue {
                skipped.append(Skipped(input: url, reason: "\(url.lastPathComponent) is a folder. Ameya works on files."))
            } else if !FileManager.default.isReadableFile(atPath: url.path) {
                skipped.append(Skipped(input: url, reason: "Ameya isn't allowed to read \(url.lastPathComponent)."))
            } else if let format = FileFormat.detectForConversion(at: url) {
                files.append((url, format))
            } else {
                skipped.append(Skipped(input: url, reason: "\(url.lastPathComponent) is empty or isn't a file Ameya can read."))
            }
        }
        return (files, skipped)
    }

    // MARK: Planning

    struct PlannedJob {
        let inputs: [URL]
        let formats: [FileFormat]
        let destination: URL
        let isFolder: Bool
        let request: ConversionRequest

        var timeout: Duration {
            if case .ocr = request.options.pdf { return .seconds(3600) }
            return formats.map(\.family.timeout).max() ?? .seconds(300)
        }
    }

    /// One job per file that can become `target`; the rest are skipped with a reason.
    func planConversion(_ urls: [URL], to target: FileFormat, in directory: URL)
        -> (jobs: [PlannedJob], skipped: [Skipped]) {
        let detected = Self.detect(urls)
        var skipped = detected.skipped
        var reserved: Set<URL> = []
        var jobs: [PlannedJob] = []
        for (url, format) in detected.files {
            guard matrix.targets(for: format).contains(target) else {
                skipped.append(Skipped(input: url, reason: "\(url.lastPathComponent) (\(format.displayName)) can't become \(target.displayName)."))
                continue
            }
            let destination = OutputPlanner.destination(for: url, target: target, in: directory) { candidate in
                reserved.contains(candidate.standardizedFileURL) || FileManager.default.fileExists(atPath: candidate.path)
            }
            reserved.insert(destination.standardizedFileURL)
            jobs.append(PlannedJob(inputs: [url], formats: [format], destination: destination, isFolder: false,
                                   request: ConversionRequest(source: format, target: target)))
        }
        return (jobs, skipped)
    }

    /// The jobs `tool` makes for these files (one per file, or one over all of them).
    func planTool(_ tool: Tool, on urls: [URL], in directory: URL) throws -> (jobs: [PlannedJob], skipped: [Skipped]) {
        guard tool.panel == nil else { throw Failure.toolNeedsApp(tool.title) }
        let (files, skipped) = Self.detect(urls)
        guard !files.isEmpty else { return ([], skipped) }
        let formats = files.map(\.1)
        guard tool.isAvailable(formats) else {
            let kinds = Set(formats.map(\.displayName)).sorted().joined(separator: ", ")
            let needs = tool.mode == .allTogether ? " (it needs at least two suitable files)" : ""
            throw Failure.nothingSuitable("\"\(tool.title)\" doesn't work on \(kinds) files\(needs).")
        }
        let groups: [[(URL, FileFormat)]] = switch tool.mode {
        case .eachFile: files.map { [$0] }
        case .allTogether: [files]
        }
        var reserved: Set<URL> = []
        let isTaken: (URL) -> Bool = { candidate in
            reserved.contains(candidate.standardizedFileURL) || FileManager.default.fileExists(atPath: candidate.path)
        }
        var jobs: [PlannedJob] = []
        for group in groups {
            let (first, firstFormat) = group[0]
            var request = tool.makeRequest(firstFormat)
            if group.count > 1 { request.inputs = group.map(\.1) }
            let suffix = tool.outputSuffix(for: request.options)
            let isFolder = tool.producesFolder(for: request.options)
            let destination = isFolder
                ? OutputPlanner.folderDestination(for: first, suffix: suffix, in: directory, isTaken: isTaken)
                : OutputPlanner.destination(for: first, target: request.target, in: directory, suffix: suffix, isTaken: isTaken)
            reserved.insert(destination.standardizedFileURL)
            jobs.append(PlannedJob(inputs: group.map(\.0), formats: group.map(\.1), destination: destination,
                                   isFolder: isFolder, request: request))
        }
        return (jobs, skipped)
    }

    // MARK: Running

    /// Runs the jobs one after another, each in a fresh sandboxed worker.
    func run(_ jobs: [PlannedJob], in directory: URL,
             progress: @escaping @Sendable (Int, Double) -> Void = { _, _ in }) async -> [Outcome] {
        if !jobs.isEmpty {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return jobs.map { Outcome(inputs: $0.inputs, output: nil, files: [], result: nil,
                                          error: "Couldn't create the folder \(directory.path).") }
            }
        }
        var outcomes: [Outcome] = []
        for (index, job) in jobs.enumerated() {
            let runner = WorkerRunner(executable: worker, timeout: job.timeout)
            do {
                let result = try await runner.run(inputs: job.inputs, destination: job.destination, request: job.request) { value in
                    progress(index, value)
                }
                let files = job.isFolder
                    ? (result.outputNames ?? []).map { job.destination.appendingPathComponent($0) }
                    : [job.destination]
                outcomes.append(Outcome(inputs: job.inputs, output: job.destination, files: files, result: result, error: nil))
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                outcomes.append(Outcome(inputs: job.inputs, output: nil, files: [], result: nil, error: message))
            }
        }
        return outcomes
    }
}
