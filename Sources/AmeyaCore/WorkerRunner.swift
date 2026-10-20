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
        }
    }
}

/// Runs one conversion in its own worker process.
///
/// Each job gets a fresh process, so a hang, crash or runaway allocation affects only that job.
/// The source is handed over as a read-only file descriptor, and the output is written to a hidden
/// temporary file that is moved into place only after the worker reports success, never over an
/// existing file.
public struct WorkerRunner: Sendable {
    public let executable: URL
    public var timeout: Duration

    public init(executable: URL, timeout: Duration = .seconds(300)) {
        self.executable = executable
        self.timeout = timeout
    }

    public func run(
        input: URL,
        destination: URL,
        request: ConversionRequest,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ConversionResult {
        let inputHandle: FileHandle
        do {
            inputHandle = try FileHandle(forReadingFrom: input)
        } catch {
            throw WorkerError.cannotOpenInput(input.lastPathComponent)
        }
        defer { try? inputHandle.close() }

        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil),
              let outputHandle = try? FileHandle(forWritingTo: partial) else {
            throw WorkerError.cannotCreateOutput(destination.lastPathComponent)
        }
        var succeeded = false
        defer {
            try? outputHandle.close()
            if !succeeded { try? FileManager.default.removeItem(at: partial) }
        }

        let job = WorkerProcess(executable: executable, progress: progress)
        let result = try await job.run(
            arguments: [WorkerProtocol.requestArgument, try WorkerProtocol.encode(request)],
            stdin: inputHandle,
            stdout: outputHandle,
            timeout: timeout
        )
        try outputHandle.synchronize()

        let written = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int) ?? -1
        guard written == result.outputBytes else {
            throw WorkerError.protocolViolation("reported \(result.outputBytes) bytes, wrote \(written)")
        }
        // RENAME_EXCL: fail instead of replacing a file that appeared in the meantime.
        guard renamex_np(partial.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw WorkerError.outputExists(destination.lastPathComponent) }
            throw WorkerError.cannotCreateOutput(destination.lastPathComponent)
        }
        succeeded = true
        return result
    }
}

/// One running worker process and the state shared with its callbacks.
final class WorkerProcess: @unchecked Sendable {
    private let process = Process()
    private let stderr = Pipe()
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var buffer = Data()
    private var result: ConversionResult?
    private var errorMessage: String?
    private var protocolProblem: String?
    private var stopReason: WorkerError?

    init(executable: URL, progress: @escaping @Sendable (Double) -> Void) {
        process.executableURL = executable
        self.progress = progress
    }

    func run(arguments: [String], stdin: FileHandle, stdout: FileHandle, timeout: Duration) async throws -> ConversionResult {
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }

        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled {
                self?.stop(.timedOut(seconds: Double(timeout.components.seconds)))
            }
        }
        defer { watchdog.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: WorkerError.failed("Couldn't start the converter: \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            stop(.cancelled)
        }

        stderr.fileHandleForReading.readabilityHandler = nil
        consume((try? stderr.fileHandleForReading.readToEnd()) ?? Data())
        consume(Data("\n".utf8)) // flush a final line without a newline

        return try lock.withLock {
            if let stopReason { throw stopReason }
            if process.terminationReason == .uncaughtSignal {
                throw WorkerError.crashed(signal: process.terminationStatus)
            }
            if let protocolProblem { throw WorkerError.protocolViolation(protocolProblem) }
            if process.terminationStatus != 0 || result == nil {
                throw WorkerError.failed(errorMessage ?? "The converter stopped with status \(process.terminationStatus).")
            }
            return result!
        }
    }

    /// Kills the worker immediately. The output is a temporary file, so nothing needs flushing.
    func stop(_ reason: WorkerError) {
        lock.withLock {
            if stopReason == nil { stopReason = reason }
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        lines.forEach(handle)
    }

    private func handle(_ line: String) {
        if line.hasPrefix(WorkerProtocol.progressPrefix) {
            if let value = Double(line.dropFirst(WorkerProtocol.progressPrefix.count)) {
                progress(min(max(value, 0), 1))
            }
        } else if line.hasPrefix(WorkerProtocol.donePrefix) {
            let json = Data(line.dropFirst(WorkerProtocol.donePrefix.count).utf8)
            lock.withLock {
                if let decoded = try? JSONDecoder().decode(ConversionResult.self, from: json) {
                    result = decoded
                } else {
                    protocolProblem = "unreadable result"
                }
            }
        } else if line.hasPrefix(WorkerProtocol.errorPrefix) {
            let message = String(line.dropFirst(WorkerProtocol.errorPrefix.count))
            lock.withLock { errorMessage = message }
        }
    }
}
