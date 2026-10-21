import AmeyaCore
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
    let source: URL
    let sourceFormat: FileFormat
    let destination: URL
    let target: FileFormat
    @Published var state: State = .queued
    @Published var progress: Double = 0
    var task: Task<Void, Never>?

    init(source: URL, sourceFormat: FileFormat, destination: URL, target: FileFormat) {
        self.source = source
        self.sourceFormat = sourceFormat
        self.destination = destination
        self.target = target
    }
}

/// Owns the queue. All file work happens in worker processes; this class only schedules and reports.
@MainActor
final class JobStore: ObservableObject {
    @Published private(set) var pending: [PendingFile] = []
    @Published private(set) var unsupported: [String] = []
    @Published private(set) var jobs: [Job] = []

    let matrix = ConversionMatrix(writable: FileFormat.systemWritable())
    /// Where conversions are saved: Settings' choice (OutputLocation.swift), or a one-off override.
    var outputDirectory: URL { directoryOverride ?? OutputLocation.directory(default: defaultOutputDirectory) }
    let defaultOutputDirectory: URL
    private var directoryOverride: URL?
    private let worker: URL?
    private let maxConcurrent = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    private var running = 0
    private var reserved: Set<URL> = []

    init() {
        defaultOutputDirectory = Self.realDownloadsDirectory().appendingPathComponent("Ameya", isDirectory: true)
        worker = Bundle.main.url(forAuxiliaryExecutable: "AmeyaWorker")
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
            if let format = FileFormat.detect(at: url) {
                pending.append(PendingFile(url: url, format: format))
            } else {
                unsupported.append(url.lastPathComponent)
            }
        }
    }

    func clearPending() {
        pending = []
        unsupported = []
    }

    func convert(to target: FileFormat) {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for file in pending {
            let destination = OutputPlanner.destination(for: file.url, target: target, in: outputDirectory) { candidate in
                reserved.contains(candidate) || FileManager.default.fileExists(atPath: candidate.path)
            }
            reserved.insert(destination)
            jobs.insert(Job(source: file.url, sourceFormat: file.format, destination: destination, target: target), at: 0)
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

    func cancel(_ job: Job) {
        if job.state == .queued {
            job.state = .cancelled
            reserved.remove(job.destination)
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
        guard let worker else {
            job.state = .failed("The converter is missing from the app bundle.")
            return
        }
        let runner = WorkerRunner(executable: worker, timeout: job.sourceFormat.family.timeout)
        running += 1
        job.state = .running
        job.task = Task { [weak self] in
            let request = ConversionRequest(source: job.sourceFormat, target: job.target)
            do {
                let result = try await runner.run(input: job.source, destination: job.destination, request: request) { value in
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
        reserved.remove(job.destination)
        job.source.stopAccessingSecurityScopedResource()
        startQueuedJobs()
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
