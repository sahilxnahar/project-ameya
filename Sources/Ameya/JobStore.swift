import AmeyaCore
import Combine
import Foundation

/// A file waiting for the user to pick a target format.
struct PendingFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let format: FileFormat
}

@MainActor
final class Job: ObservableObject, Identifiable {
    enum State: Equatable {
        case queued
        case running
        case done(ConversionResult)
        case failed(String)
        case cancelled

        var isFinished: Bool {
            switch self {
            case .queued, .running: false
            case .done, .failed, .cancelled: true
            }
        }
    }

    let id = UUID()
    /// One file, or several for tools that work on all files together (in order).
    let sources: [URL]
    let sourceFormats: [FileFormat]
    /// A file, or a folder when `isFolder` (tools that produce several files).
    let destination: URL
    let isFolder: Bool
    /// Built up front: a plain conversion or a tool's request.
    let request: ConversionRequest
    /// The tool's name, for status text. `nil` for a plain conversion.
    let toolTitle: String?
    /// Total size of the sources when the job was queued, for "62% smaller".
    let sourceBytes: Int64
    @Published var state: State = .queued
    @Published var progress: Double = 0
    var task: Task<Void, Never>?

    init(sources: [URL], sourceFormats: [FileFormat], destination: URL, isFolder: Bool = false,
         request: ConversionRequest, toolTitle: String? = nil) {
        self.sources = sources
        self.sourceFormats = sourceFormats
        self.destination = destination
        self.isFolder = isFolder
        self.request = request
        self.toolTitle = toolTitle
        sourceBytes = sources.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    var target: FileFormat { request.target }

    /// What the row says while the job runs.
    var activity: String {
        let subject = sources.count == 1 ? sources[0].lastPathComponent : "\(sources.count) files"
        if let toolTitle { return "\(toolTitle): \(subject)…" }
        return "Converting \(subject)…"
    }

    /// The longest timeout among the sources' families.
    var timeout: Duration {
        // Text recognition reads every scanned page (and loads its models the first time).
        if case .ocr = request.options.pdf { return .seconds(3600) }
        return sourceFormats.map(\.family.timeout).max() ?? .seconds(300)
    }
}

/// Owns the queue. All file work happens in worker processes; this class only schedules and reports.
@MainActor
final class JobStore: ObservableObject {
    @Published private(set) var pending: [PendingFile] = []
    @Published private(set) var unsupported: [String] = []
    @Published private(set) var jobs: [Job] = []
    /// Sent once for every job that ends (done, failed or cancelled). Results and Recent listen.
    let finished = PassthroughSubject<Job, Never>()

    let matrix: ConversionMatrix
    let catalog: ToolCatalog
    /// Where conversions are saved: Settings' choice (OutputLocation.swift), or a one-off override.
    var outputDirectory: URL { directoryOverride ?? OutputLocation.directory(default: defaultOutputDirectory) }
    let defaultOutputDirectory: URL
    private var directoryOverride: URL?
    private let maxConcurrent = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    private var running = 0
    private var reserved: Set<URL> = []

    init() {
        let writable = FileFormat.systemWritable()
        matrix = ConversionMatrix(writable: writable)
        catalog = ToolCatalog(writable: writable)
        defaultOutputDirectory = Self.realDownloadsDirectory().appendingPathComponent("Ameya", isDirectory: true)
        Self.removeStaleScratchFolders()
    }

    var targets: [FileFormat] {
        matrix.commonTargets(for: pending.map(\.format))
    }

    func possibleLosses(to target: FileFormat) -> [ConversionNote] {
        var seen: [ConversionNote] = []
        for file in pending {
            for note in matrix.possibleLosses(from: file.format, to: target) where !seen.contains(note) {
                seen.append(note)
            }
        }
        return seen
    }

    func add(_ urls: [URL]) {
        unsupported = []
        for url in urls {
            _ = url.startAccessingSecurityScopedResource()
            guard !pending.contains(where: { $0.url == url }) else { continue }
            if let format = FileFormat.detectForConversion(at: url) {
                pending.append(PendingFile(url: url, format: format))
            } else {
                unsupported.append(url.lastPathComponent)
            }
        }
    }

    func remove(_ file: PendingFile) {
        pending.removeAll { $0.id == file.id }
        file.url.stopAccessingSecurityScopedResource()
    }

    func clearPending() {
        pending = []
        unsupported = []
    }

    /// Tools that apply to every pending file.
    var tools: [Tool] {
        catalog.available(for: pending.map(\.format))
    }

    func convert(to target: FileFormat) {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for file in pending {
            let destination = OutputPlanner.destination(for: file.url, target: target, in: outputDirectory, isTaken: isTaken)
            enqueue(Job(sources: [file.url], sourceFormats: [file.format], destination: destination,
                        request: ConversionRequest(source: file.format, target: target)))
        }
        pending = []
        startQueuedJobs()
    }

    /// Queues `urls` straight to `target` (Services, auto-convert) without touching what the
    /// user has pending. Files that can't become `target` are skipped. Returns the new jobs.
    @discardableResult
    func convertNow(_ urls: [URL], to target: FileFormat, in directory: URL? = nil) -> [Job] {
        let savedPending = pending, savedUnsupported = unsupported
        pending = []
        add(urls)
        pending.removeAll { !matrix.targets(for: $0.format).contains(target) }
        let before = Set(jobs.map(\.id))
        directoryOverride = directory
        if !pending.isEmpty { convert(to: target) }
        directoryOverride = nil
        pending = savedPending
        unsupported = savedUnsupported
        return jobs.filter { !before.contains($0.id) }
    }

    /// Runs `tool` on `urls` straight away (the drag wheel) without touching what the user has
    /// pending. Does nothing if the tool doesn't suit every file. Returns the new jobs.
    @discardableResult
    func runNow(_ tool: Tool, on urls: [URL]) -> [Job] {
        let savedPending = pending, savedUnsupported = unsupported
        pending = []
        add(urls)
        let before = Set(jobs.map(\.id))
        run(tool)
        pending = savedPending
        unsupported = savedUnsupported
        return jobs.filter { !before.contains($0.id) }
    }

    /// Runs `tool` on the pending files. `options`, from the tool's panel, replace the tool's own.
    func run(_ tool: Tool, options: ConversionOptions? = nil) {
        guard !pending.isEmpty, tool.isAvailable(pending.map(\.format)) else { return }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let groups: [[PendingFile]] = switch tool.mode {
        case .eachFile: pending.map { [$0] }
        case .allTogether: [pending]
        }
        for files in groups {
            let first = files[0]
            var request = tool.makeRequest(first.format)
            if let options { request.options = options }
            if files.count > 1 { request.inputs = files.map(\.format) }
            let suffix = tool.outputSuffix(for: request.options)
            let isFolder = tool.producesFolder(for: request.options)
            let destination = isFolder
                ? OutputPlanner.folderDestination(for: first.url, suffix: suffix, in: outputDirectory, isTaken: isTaken)
                : OutputPlanner.destination(for: first.url, target: request.target, in: outputDirectory,
                                            suffix: suffix, isTaken: isTaken)
            enqueue(Job(sources: files.map(\.url), sourceFormats: files.map(\.format), destination: destination,
                        isFolder: isFolder, request: request, toolTitle: tool.title))
        }
        pending = []
        startQueuedJobs()
    }

    private func isTaken(_ candidate: URL) -> Bool {
        reserved.contains(candidate.standardizedFileURL) || FileManager.default.fileExists(atPath: candidate.path)
    }

    private func enqueue(_ job: Job) {
        reserved.insert(job.destination.standardizedFileURL)
        jobs.insert(job, at: 0)
    }

    func cancel(_ job: Job) {
        if job.state == .queued {
            job.state = .cancelled
            release(job)
            finished.send(job)
        } else {
            job.task?.cancel()
        }
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
    }

    private func startQueuedJobs() {
        // Oldest first: jobs are displayed newest-first.
        for job in jobs.reversed() where job.state == .queued && running < maxConcurrent {
            start(job)
        }
    }

    private func start(_ job: Job) {
        guard let runner = WorkerRunner.bundled(timeout: job.timeout) else {
            job.state = .failed("The converter is missing from the app bundle.")
            finished.send(job)
            return
        }
        running += 1
        job.state = .running
        job.task = Task { [weak self] in
            if job.sources.count == 1, ConversionMatrix.isTranscription(from: job.sourceFormats[0], to: job.target),
               let problem = await SpeechSetup.prepare(language: job.request.options.language) {
                job.state = .failed(problem)
                self?.finish(job)
                return
            }
            do {
                let result = try await runner.run(inputs: job.sources, destination: job.destination, request: job.request) { value in
                    Task { @MainActor in job.progress = value }
                }
                job.progress = 1
                job.state = .done(result)
            } catch WorkerError.cancelled {
                job.state = .cancelled
            } catch {
                job.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self?.finish(job)
        }
    }

    private func finish(_ job: Job) {
        running -= 1
        release(job)
        finished.send(job)
        startQueuedJobs()
    }

    private func release(_ job: Job) {
        reserved.remove(job.destination.standardizedFileURL)
        job.sources.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    /// Workers delete their scratch folder when they finish; one that was killed can't.
    /// Anything older than an hour belongs to no running job.
    static func removeStaleScratchFolders() {
        let temporary = FileManager.default.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-3600)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: temporary, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix("ameya-worker-") {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: entry) }
        }
    }

    /// The user's real Downloads folder. Inside the sandbox, `FileManager` would return the
    /// container's copy; the downloads entitlement grants access to the real one.
    static func realDownloadsDirectory() -> URL {
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Downloads", isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }
}
