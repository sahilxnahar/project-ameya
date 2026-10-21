import Darwin
import Foundation

/// The messages between the app and its `AmeyaLauncher` XPC service.
///
/// The service is sandboxed with no file entitlements. Workers it starts inherit *its* sandbox,
/// so they can't open Downloads, the output folder or anything the user dropped; the app hands
/// each worker exactly three descriptors (source, partial output, status pipe) instead.
@objc public protocol AmeyaLauncherXPC {
    /// Starts the bundled worker with these as stdin, stdout and stderr. Replies with its pid,
    /// or 0 and a message.
    func launch(_ arguments: [String], stdin: FileHandle, stdout: FileHandle, stderr: FileHandle,
                reply: @escaping @Sendable (Int32, String?) -> Void)
    /// Replies with (exit status, signal) once the worker has exited and its group is stopped.
    func waitForExit(_ pid: Int32, reply: @escaping @Sendable (Int32, Int32) -> Void)
    /// Replies with the physical footprint of the worker's process group, in bytes.
    func footprint(_ pid: Int32, reply: @escaping @Sendable (UInt64) -> Void)
    /// Stops the worker and its process group.
    func terminate(_ pid: Int32)
}

/// The app's side: starts workers through the XPC service.
public final class XPCWorkerLauncher: WorkerLauncher, @unchecked Sendable {
    public static let serviceName = "io.github.sahilxnahar.ameya.Launcher"
    public static let bundleName = "AmeyaLauncher.xpc"
    private let connection: NSXPCConnection

    public init() {
        connection = NSXPCConnection(serviceName: Self.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: AmeyaLauncherXPC.self)
        connection.resume()
    }

    deinit { connection.invalidate() }

    /// Whether this app bundle contains the service.
    public static var isBundled: Bool {
        let service = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/\(bundleName)")
        return FileManager.default.fileExists(atPath: service.path)
    }

    private func proxy(onError: @escaping @Sendable (Error) -> Void) -> AmeyaLauncherXPC? {
        connection.remoteObjectProxyWithErrorHandler(onError) as? AmeyaLauncherXPC
    }

    public func launch(arguments: [String], stdin: FileHandle, stdout: FileHandle, stderr: FileHandle) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            let once = Once()
            let failed: @Sendable (String) -> Void = { message in
                once.run { continuation.resume(throwing: WorkerError.failed("Couldn't start the converter: \(message)")) }
            }
            guard let proxy = proxy(onError: { failed($0.localizedDescription) }) else { return failed("no service") }
            proxy.launch(arguments, stdin: stdin, stdout: stdout, stderr: stderr) { pid, message in
                if pid > 0 { once.run { continuation.resume(returning: pid) } } else { failed(message ?? "unknown error") }
            }
        }
    }

    public func waitForExit(_ pid: Int32) async -> WorkerSpawn.Exit {
        await withCheckedContinuation { continuation in
            let once = Once()
            // If the service itself went away, its workers went with it.
            let lost: @Sendable (Error) -> Void = { _ in
                once.run { continuation.resume(returning: WorkerSpawn.Exit(status: 0, signal: SIGKILL)) }
            }
            guard let proxy = proxy(onError: lost) else { return lost(CocoaError(.featureUnsupported)) }
            proxy.waitForExit(pid) { status, signal in
                once.run { continuation.resume(returning: WorkerSpawn.Exit(status: status, signal: signal)) }
            }
        }
    }

    public func footprint(_ pid: Int32) async -> UInt64 {
        await withCheckedContinuation { continuation in
            let once = Once()
            guard let proxy = proxy(onError: { _ in once.run { continuation.resume(returning: 0) } }) else {
                return continuation.resume(returning: 0)
            }
            proxy.footprint(pid) { bytes in once.run { continuation.resume(returning: bytes) } }
        }
    }

    public func terminate(_ pid: Int32) {
        proxy(onError: { _ in })?.terminate(pid)
    }
}

/// The service's side: one instance per connection, so a connection only controls its own workers.
public final class LauncherService: NSObject, AmeyaLauncherXPC, @unchecked Sendable {
    private let worker: URL
    private let lock = NSLock()
    private var running: Set<Int32> = []
    private var exits: [Int32: WorkerSpawn.Exit] = [:]
    private var waiters: [Int32: [@Sendable (Int32, Int32) -> Void]] = [:]

    public init(worker: URL) {
        self.worker = worker
    }

    public func launch(_ arguments: [String], stdin: FileHandle, stdout: FileHandle, stderr: FileHandle,
                       reply: @escaping @Sendable (Int32, String?) -> Void) {
        defer {
            // The worker has its own copies now; the app's stderr pipe must see EOF when it exits.
            try? stdin.close()
            try? stdout.close()
            try? stderr.close()
        }
        // Only the two things a worker is for: a conversion request, or the self-test's sandbox probe.
        guard arguments.count == 2, [WorkerProtocol.requestArgument, SandboxProbe.argument].contains(arguments[0]) else {
            return reply(0, "unexpected arguments")
        }
        let pid: pid_t
        do {
            pid = try WorkerSpawn.spawn(executable: worker.path, arguments: arguments, stdin: stdin.fileDescriptor,
                                        stdout: stdout.fileDescriptor, stderr: stderr.fileDescriptor)
        } catch {
            return reply(0, error.localizedDescription)
        }
        lock.withLock { _ = running.insert(pid) }
        Thread.detachNewThread { [self] in
            let exit = WorkerSpawn.waitForExit(pid)
            let callbacks = lock.withLock {
                running.remove(pid)
                // Kept for a `waitForExit` that hasn't arrived yet.
                guard let waiting = waiters.removeValue(forKey: pid) else {
                    exits[pid] = exit
                    return [@Sendable (Int32, Int32) -> Void]()
                }
                return waiting
            }
            callbacks.forEach { $0(exit.status, exit.signal) }
        }
        reply(pid, nil)
    }

    public func waitForExit(_ pid: Int32, reply: @escaping @Sendable (Int32, Int32) -> Void) {
        let finished: WorkerSpawn.Exit? = lock.withLock {
            if let exit = exits.removeValue(forKey: pid) { return exit }
            guard running.contains(pid) else { return WorkerSpawn.Exit(status: 0, signal: SIGKILL) }
            waiters[pid, default: []].append(reply)
            return nil
        }
        if let finished { reply(finished.status, finished.signal) }
    }

    public func footprint(_ pid: Int32, reply: @escaping @Sendable (UInt64) -> Void) {
        reply(lock.withLock { running.contains(pid) } ? WorkerSpawn.groupFootprint(pid) : 0)
    }

    public func terminate(_ pid: Int32) {
        if lock.withLock({ running.contains(pid) }) { WorkerSpawn.killGroup(pid) }
    }

    /// The app went away (or dropped the connection): stop everything it started.
    public func terminateAll() {
        lock.withLock { running }.forEach(WorkerSpawn.killGroup)
    }
}

/// Runs a closure at most once, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
