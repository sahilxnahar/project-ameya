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
    let destination: URL
    let target: FileFormat
    @Published var state: State = .queued
    @Published var progress: Double = 0
    var task: Task<Void, Never>?

    init(source: URL, destination: URL, target: FileFormat) {
        self.source = source
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
    let outputDirectory: URL
    private let runner: WorkerRunner?
    private let maxConcurrent = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    private var running = 0
    private var reserved: Set<URL> = []

    init() {
        outputDirectory = Self.realDownloadsDirectory().appendingPathComponent("Ameya", isDirectory: true)
        runner = Bundle.main.url(forAuxiliaryExecutable: "AmeyaWorker").map { WorkerRunner(executable: $0) }
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
            jobs.insert(Job(source: file.url, destination: destination, target: target), at: 0)
        }
        pending = []
        startQueuedJobs()
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
        guard let runner else {
            job.state = .failed("The converter is missing from the app bundle.")
            return
        }
        running += 1
        job.state = .running
        job.task = Task { [weak self] in
            let request = ConversionRequest(target: job.target)
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

    /// The user's real Downloads folder. Inside the sandbox, `FileManager` would return the
    /// container's copy; the downloads entitlement grants access to the real one.
    static func realDownloadsDirectory() -> URL {
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Downloads", isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }
}
