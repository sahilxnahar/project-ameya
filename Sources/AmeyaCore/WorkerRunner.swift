import Darwin
import Foundation

/// The line protocol between the app and the worker process.
///
/// The worker gets the request as JSON after `--request`, reads the source from stdin and writes
/// the converted file to stdout. Status goes to stderr, one line each:
/// `AMEYA:progress:<0…1>`, then exactly one of `AMEYA:done:<ConversionResult JSON>` or `AMEYA:error:<message>`.
public enum WorkerProtocol {
    public static let requestArgument = "--request"
    public static let progressPrefix = "AMEYA:progress:"
    public static let donePrefix = "AMEYA:done:"
    public static let errorPrefix = "AMEYA:error:"
    /// Longest status line accepted; a worker that sends more without a newline is stopped.
    public static let maxLineBytes = 64 << 10

    public static func encode(_ request: ConversionRequest) throws -> String {
        String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    }

    public static func decodeRequest(_ argument: String) throws -> ConversionRequest {
        try JSONDecoder().decode(ConversionRequest.self, from: Data(argument.utf8))
    }

    public static func encode(_ result: ConversionResult) throws -> String {
        String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }
}

public enum WorkerError: Error, Equatable, LocalizedError {
    case timedOut(seconds: Double)
    case cancelled
    case crashed(signal: Int32)
    case failed(String)
    case outputExists(String)
    case cannotOpenInput(String)
    case cannotCreateOutput(String)
    case protocolViolation(String)
    case tooMuchMemory
    case outputTooLarge(bytes: Int64)
    case notEnoughSpace(needed: Int64)
    case diskFull

    public var errorDescription: String? {
        switch self {
        case .timedOut(let seconds): "Stopped after \(Int(seconds)) seconds without finishing."
        case .cancelled: "Cancelled."
        case .crashed(let signal): "The converter crashed (signal \(signal)). Your original file is untouched."
        case .failed(let message): message
        case .outputExists(let name): "\(name) already exists, so nothing was overwritten."
        case .cannotOpenInput(let name): "Couldn't open \(name)."
        case .cannotCreateOutput(let name): "Couldn't create \(name)."
        case .protocolViolation(let detail): "The converter sent an unexpected reply: \(detail)"
        case .tooMuchMemory:
            "This file needed more memory than is safe to use, so Ameya stopped. Your original file is untouched."
        case .outputTooLarge(let bytes):
            "The result grew past \(Self.format(bytes)), far more than this file should need, so Ameya stopped to protect your disk."
        case .notEnoughSpace(let needed):
            "There isn't enough free disk space for this (about \(Self.format(needed)) is needed). Free up some space and try again."
        case .diskFull: "Your disk is almost full, so Ameya stopped. Free up some space and try again."
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Runs one conversion in its own worker process.
///
/// Each job gets a fresh process, so a hang, crash or runaway allocation affects only that job.
/// The source is handed over as a read-only file descriptor, and the output is written to a hidden
/// temporary file that is moved into place only after the worker reports success, never over an
/// existing file. Memory, output size and free disk space are watched while it runs (`WorkerLimits`).
public struct WorkerRunner: Sendable {
    public let launcher: any WorkerLauncher
    public var timeout: Duration
    /// `nil` works them out per job from its formats and input size.
    public var limits: WorkerLimits?

    /// Runs `executable` as a child of this process (tests, development).
    public init(executable: URL, timeout: Duration = .seconds(300)) {
        self.init(launcher: LocalWorkerLauncher(executable: executable), timeout: timeout)
    }

    public init(launcher: any WorkerLauncher, timeout: Duration = .seconds(300), limits: WorkerLimits? = nil) {
        self.launcher = launcher
        self.timeout = timeout
        self.limits = limits
    }

    /// The app's runner: workers start in the `AmeyaLauncher` XPC service, whose sandbox has no
    /// access to the user's files. A bundle without the service (`swift run`) runs the worker
    /// directly; it then sandboxes itself, and refuses to run if it could reach the user's files.
    public static func bundled(timeout: Duration) -> WorkerRunner? {
        if XPCWorkerLauncher.isBundled { return WorkerRunner(launcher: XPCWorkerLauncher(), timeout: timeout) }
        guard let worker = Bundle.main.url(forAuxiliaryExecutable: "AmeyaWorker") else { return nil }
        return WorkerRunner(executable: worker, timeout: timeout)
    }

    /// Converts one file. See `run(inputs:destination:request:progress:)`.
    public func run(
        input: URL,
        destination: URL,
        request: ConversionRequest,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ConversionResult {
        try await run(inputs: [input], destination: destination, request: request, progress: progress)
    }

    /// Runs one job over one or more source files.
    ///
    /// - Several inputs are bundled, in order, into a temporary TAR stream (entries `0.ext`, `1.ext`, …)
    ///   that becomes the worker's stdin; it is deleted afterwards. `request.inputs` names their formats
    ///   (filled in by detection when `nil`).
    /// - When the worker reports `outputNames`, its output is a TAR stream: it is unpacked with the
    ///   strict reader into a hidden partial folder, checked against `outputNames`, and that folder is
    ///   moved to `destination` (never over anything existing). Otherwise `destination` is a file.
    public func run(
        inputs: [URL],
        destination: URL,
        request: ConversionRequest,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ConversionResult {
        guard let first = inputs.first else { throw WorkerError.cannotOpenInput("(no files)") }
        var request = request
        var bundle: URL?
        defer { if let bundle { try? FileManager.default.removeItem(at: bundle) } }

        let inputBytes = inputs.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        let needed = WorkerLimits.requiredFreeBytes(inputBytes: inputBytes)
        if let free = WorkerLimits.freeBytes(at: destination.deletingLastPathComponent()), free < needed {
            throw WorkerError.notEnoughSpace(needed: needed)
        }

        let inputHandle: FileHandle
        if inputs.count == 1 {
            do {
                inputHandle = try FileHandle(forReadingFrom: first)
            } catch {
                throw WorkerError.cannotOpenInput(first.lastPathComponent)
            }
        } else {
            let formats = try request.inputs ?? inputs.map { url in
                guard let format = FileFormat.detect(at: url) else { throw WorkerError.cannotOpenInput(url.lastPathComponent) }
                return format
            }
            guard formats.count == inputs.count else {
                throw WorkerError.failed("The request lists \(formats.count) formats for \(inputs.count) files.")
            }
            request.inputs = formats
            let tar = temporaryDirectory.appendingPathComponent("ameya-inputs-\(UUID().uuidString).tar")
            bundle = tar
            try Self.bundle(inputs, formats: formats, into: tar)
            inputHandle = try FileHandle(forReadingFrom: tar)
        }
        defer { try? inputHandle.close() }
        let families = (request.inputs ?? request.source.map { [$0] } ?? []).map(\.family) + [request.target.family]
        let limits = limits ?? WorkerLimits.forJob(families: families, inputBytes: inputBytes)
        // A password travels ahead of the file on stdin, never on the command line (WorkerSecret).
        var workerStdin = inputHandle
        if let secret = WorkerSecret.extract(from: &request) {
            workerStdin = try WorkerSecret.stdin(prefixing: secret, to: inputHandle)
        }
        defer { if workerStdin !== inputHandle { try? workerStdin.close() } }

        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        // A sibling hidden folder for several outputs; also ends in ".partial" so cleanup finds it.
        let partialFolder = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial", isDirectory: true)
        Self.active.insert([partial, partialFolder])
        defer { Self.active.remove([partial, partialFolder]) }
        guard FileManager.default.createFile(atPath: partial.path, contents: nil),
              let outputHandle = try? FileHandle(forWritingTo: partial) else {
            throw WorkerError.cannotCreateOutput(destination.lastPathComponent)
        }
        var succeeded = false
        defer {
            try? outputHandle.close()
            // After a single-file success it has been renamed away; after a multi-file one it was unpacked.
            try? FileManager.default.removeItem(at: partial)
            if !succeeded { try? FileManager.default.removeItem(at: partialFolder) }
        }

        let job = WorkerProcess(launcher: launcher, limits: limits, progress: progress)
        let result = try await job.run(
            arguments: [WorkerProtocol.requestArgument, try WorkerProtocol.encode(request)],
            stdin: workerStdin,
            stdout: outputHandle,
            timeout: timeout
        )
        try outputHandle.synchronize()

        let written = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int) ?? -1
        guard written == result.outputBytes else {
            throw WorkerError.protocolViolation("reported \(result.outputBytes) bytes, wrote \(written)")
        }
        var moving = partial
        if let names = result.outputNames {
            try Self.unpack(partial, expecting: names, into: partialFolder, limits: limits)
            moving = partialFolder
        }
        // RENAME_EXCL: fail instead of replacing a file or folder that appeared in the meantime.
        guard renamex_np(moving.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw WorkerError.outputExists(destination.lastPathComponent) }
            throw WorkerError.cannotCreateOutput(destination.lastPathComponent)
        }
        succeeded = true
        return result
    }

    /// Asks the self-test's question: can a worker, started the way jobs are, open `target` by path?
    public func probeSandbox(target: URL) async throws -> SandboxProbe {
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        defer {
            try? input.close()
            try? output.close()
        }
        let job = WorkerProcess(launcher: launcher, limits: limits ?? .unlimited, progress: { _ in })
        return try await job.probe(arguments: [SandboxProbe.argument, target.path], stdin: input, stdout: output, timeout: timeout)
    }

    // MARK: Partial outputs in use

    private static let active = PathSet()

    /// Whether a job in this process is writing `url` right now (`LeftoverSweeper` skips those).
    public static func isActivePartial(_ url: URL) -> Bool {
        active.contains(url)
    }

    private static func bundle(_ inputs: [URL], formats: [FileFormat], into tar: URL) throws {
        guard FileManager.default.createFile(atPath: tar.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: tar) else {
            throw WorkerError.cannotCreateOutput(tar.lastPathComponent)
        }
        defer { try? handle.close() }
        let writer = TarStream.Writer(handle: handle)
        for (index, input) in inputs.enumerated() {
            do {
                try writer.add(name: "\(index).\(formats[index].preferredExtension)", contentsOf: input)
            } catch {
                throw WorkerError.cannotOpenInput(input.lastPathComponent)
            }
        }
        try writer.finish()
    }

    /// Strictly unpacks the worker's TAR output and checks it holds exactly `names`, in order.
    private static func unpack(_ tar: URL, expecting names: [String], into folder: URL, limits: WorkerLimits) throws {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let handle = try FileHandle(forReadingFrom: tar)
            defer { try? handle.close() }
            let size = (try? FileManager.default.attributesOfItem(atPath: tar.path)[.size] as? Int64) ?? 0
            // Exactly the files reported, and never more bytes than the stream (or the output cap) holds.
            let tarLimits = TarStream.Limits(maxEntries: names.count, maxTotalBytes: min(size, limits.outputBytes))
            let extracted = try TarStream.extract(from: handle, into: folder, limits: tarLimits)
            guard extracted == names else {
                throw WorkerError.protocolViolation("the files sent don't match the files reported")
            }
        } catch let error as WorkerError {
            throw error
        } catch {
            throw WorkerError.protocolViolation((error as? LocalizedError)?.errorDescription ?? "unreadable file bundle")
        }
    }
}

/// A thread-safe set of standardized paths.
private final class PathSet: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []
    func insert(_ urls: [URL]) { lock.withLock { urls.forEach { paths.insert($0.standardizedFileURL.path) } } }
    func remove(_ urls: [URL]) { lock.withLock { urls.forEach { paths.remove($0.standardizedFileURL.path) } } }
    func contains(_ url: URL) -> Bool { lock.withLock { paths.contains(url.standardizedFileURL.path) } }
}
