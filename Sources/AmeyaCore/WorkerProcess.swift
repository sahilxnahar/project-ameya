import Darwin
import Foundation

/// One running worker and everything watching it: status lines, the clock, memory and disk.
final class WorkerProcess: @unchecked Sendable {
    private let launcher: any WorkerLauncher
    private let limits: WorkerLimits
    private let progress: @Sendable (Double) -> Void
    private let stderr = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var pid: Int32 = 0
    private var exited = false
    private var result: ConversionResult?
    private var probeResult: SandboxProbe?
    private var errorMessage: String?
    private var protocolProblem: String?
    private var stopReason: WorkerError?

    init(launcher: any WorkerLauncher, limits: WorkerLimits, progress: @escaping @Sendable (Double) -> Void) {
        self.launcher = launcher
        self.limits = limits
        self.progress = progress
    }

    func run(arguments: [String], stdin: FileHandle, stdout: FileHandle, timeout: Duration) async throws -> ConversionResult {
        let exit = try await execute(arguments: arguments, stdin: stdin, stdout: stdout, timeout: timeout)
        return try lock.withLock {
            if let stopReason { throw stopReason }
            if exit.signal != 0 { throw WorkerError.crashed(signal: exit.signal) }
            if let protocolProblem { throw WorkerError.protocolViolation(protocolProblem) }
            guard exit.status == 0, let result else {
                throw WorkerError.failed(errorMessage ?? "The converter stopped with status \(exit.status).")
            }
            return result
        }
    }

    func probe(arguments: [String], stdin: FileHandle, stdout: FileHandle, timeout: Duration) async throws -> SandboxProbe {
        let exit = try await execute(arguments: arguments, stdin: stdin, stdout: stdout, timeout: timeout)
        return try lock.withLock {
            if let stopReason { throw stopReason }
            guard let probeResult else {
                throw WorkerError.failed(errorMessage ?? "The sandbox probe stopped with status \(exit.status), signal \(exit.signal).")
            }
            return probeResult
        }
    }

    private func execute(arguments: [String], stdin: FileHandle, stdout: FileHandle, timeout: Duration) async throws -> WorkerSpawn.Exit {
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        let pid = try await launcher.launch(arguments: arguments, stdin: stdin, stdout: stdout,
                                            stderr: stderr.fileHandleForWriting)
        // Only the worker may hold the write end, so the pipe ends when it does.
        try? stderr.fileHandleForWriting.close()
        lock.withLock { self.pid = pid }
        if Task.isCancelled { stop(.cancelled) }

        let watchdog = Task { [weak self] in await self?.watch(output: stdout.fileDescriptor, timeout: timeout) }
        let exit = await withTaskCancellationHandler {
            await launcher.waitForExit(pid)
        } onCancel: {
            stop(.cancelled)
        }
        lock.withLock { exited = true }
        watchdog.cancel()

        stderr.fileHandleForReading.readabilityHandler = nil
        consume((try? stderr.fileHandleForReading.readToEnd()) ?? Data())
        consume(Data("\n".utf8)) // flush a final line without a newline
        try? stderr.fileHandleForReading.close()
        return exit
    }

    /// Samples the worker about four times a second and stops it at the first limit it crosses.
    private func watch(output: Int32, timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while !Task.isCancelled {
            try? await Task.sleep(for: limits.sampleInterval)
            guard !Task.isCancelled, let pid = lock.withLock({ exited ? nil : pid }) else { return }
            if ContinuousClock.now >= deadline {
                return stop(.timedOut(seconds: Double(timeout.components.seconds)))
            }
            let written = WorkerLimits.size(descriptor: output)
            if written > limits.outputBytes { return stop(.outputTooLarge(bytes: limits.outputBytes)) }
            if let free = WorkerLimits.freeBytes(descriptor: output), free < limits.reserveFreeBytes {
                return stop(.diskFull)
            }
            if limits.memoryBytes < .max, await launcher.footprint(pid) > limits.memoryBytes {
                return stop(.tooMuchMemory)
            }
        }
    }

    /// Kills the worker and its process group immediately. The output is a temporary file, so
    /// nothing needs flushing.
    func stop(_ reason: WorkerError) {
        let target: Int32? = lock.withLock {
            if stopReason == nil { stopReason = reason }
            return exited || pid == 0 ? nil : pid
        }
        if let target { launcher.terminate(target) }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        var overflow = false
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            if buffer.count > WorkerProtocol.maxLineBytes {
                // A runaway line: stop listening and stop the worker rather than buffer without end.
                buffer = Data()
                if protocolProblem == nil { protocolProblem = "a status line longer than 64 KB" }
                overflow = true
            }
        }
        lines.forEach(handle)
        if overflow {
            stderr.fileHandleForReading.readabilityHandler = nil
            stop(.protocolViolation("a status line longer than 64 KB"))
        }
    }

    private func handle(_ line: String) {
        guard line.utf8.count <= WorkerProtocol.maxLineBytes else {
            lock.withLock { if protocolProblem == nil { protocolProblem = "a status line longer than 64 KB" } }
            return
        }
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
        } else if line.hasPrefix(SandboxProbe.prefix) {
            let json = Data(line.dropFirst(SandboxProbe.prefix.count).utf8)
            lock.withLock { probeResult = try? JSONDecoder().decode(SandboxProbe.self, from: json) }
        }
    }
}
