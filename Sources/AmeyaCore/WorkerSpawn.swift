import Darwin
import Foundation

/// Starts, measures, stops and reaps one worker and the process group it leads.
///
/// Used by `LocalWorkerLauncher` (tests, development) and by the `AmeyaLauncher` XPC service.
public enum WorkerSpawn {
    /// How a worker ended: `signal` is non-zero when it was killed by one.
    public struct Exit: Sendable, Equatable {
        public var status: Int32
        public var signal: Int32

        public init(status: Int32, signal: Int32) {
            self.status = status
            self.signal = signal
        }
    }

    public enum Failure: Error, LocalizedError {
        case couldNotStart(Int32)
        public var errorDescription: String? {
            switch self {
            case .couldNotStart(let code): "Couldn't start the converter (\(String(cString: strerror(code))))."
            }
        }
    }

    /// Starts `executable` as the leader of a new process group, with exactly these three
    /// descriptors as stdin, stdout and stderr; every other descriptor is closed in the child.
    public static func spawn(executable: String, arguments: [String],
                             stdin: Int32, stdout: Int32, stderr: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)

        let argv = ([executable] + arguments).map { strdup($0) }
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = (argv + [nil]).withUnsafeBufferPointer { buffer in
            posix_spawn(&pid, executable, &actions, &attributes, buffer.baseAddress, environ)
        }
        guard status == 0 else { throw Failure.couldNotStart(status) }
        return pid
    }

    /// Blocks until `pid` exits, stops whatever is left of its process group (an FFmpeg helper
    /// that outlived it), then reaps it. The group is stopped *before* reaping, while its id
    /// can't yet belong to anyone else.
    public static func waitForExit(_ pid: pid_t) -> Exit {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
        killGroup(pid)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        let signal = status & 0x7f
        return signal == 0 ? Exit(status: (status >> 8) & 0xff, signal: 0) : Exit(status: 0, signal: signal)
    }

    /// SIGKILLs the worker and everything in its process group.
    public static func killGroup(_ pid: pid_t) {
        guard pid > 0 else { return }
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
    }

    /// Physical memory used by the worker's whole process group (the worker and its FFmpeg), in bytes.
    public static func groupFootprint(_ pid: pid_t) -> UInt64 {
        var members = [pid_t](repeating: 0, count: 64)
        let bytes = members.withUnsafeMutableBytes { raw in
            proc_listpgrppids(pid, raw.baseAddress, Int32(raw.count))
        }
        var pids = Set(members.prefix(max(0, Int(bytes)) / MemoryLayout<pid_t>.size).filter { $0 > 0 })
        pids.insert(pid)
        return pids.reduce(0) { $0 + footprint($1) }
    }

    /// One process's physical footprint (what Activity Monitor calls Memory), or 0 if it's gone.
    public static func footprint(_ pid: pid_t) -> UInt64 {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? info.ri_phys_footprint : 0
    }
}

/// Starts workers and controls them for `WorkerRunner`.
public protocol WorkerLauncher: Sendable {
    /// Starts one worker with these descriptors as its stdin, stdout and stderr. Returns its pid.
    func launch(arguments: [String], stdin: FileHandle, stdout: FileHandle, stderr: FileHandle) async throws -> Int32
    /// Waits for the worker to exit; its process group is stopped by then.
    func waitForExit(_ pid: Int32) async -> WorkerSpawn.Exit
    /// The physical footprint of the worker's process group, in bytes.
    func footprint(_ pid: Int32) async -> UInt64
    /// Stops the worker and its process group now.
    func terminate(_ pid: Int32)
}

/// Runs the worker as a child of this process. Used by tests and development builds; in those
/// the worker applies its own strict sandbox profile (`WorkerSandbox`).
public struct LocalWorkerLauncher: WorkerLauncher {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    public func launch(arguments: [String], stdin: FileHandle, stdout: FileHandle, stderr: FileHandle) async throws -> Int32 {
        try WorkerSpawn.spawn(executable: executable.path, arguments: arguments,
                              stdin: stdin.fileDescriptor, stdout: stdout.fileDescriptor, stderr: stderr.fileDescriptor)
    }

    public func waitForExit(_ pid: Int32) async -> WorkerSpawn.Exit {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: WorkerSpawn.waitForExit(pid)) }
        }
    }

    public func footprint(_ pid: Int32) async -> UInt64 {
        WorkerSpawn.groupFootprint(pid)
    }

    public func terminate(_ pid: Int32) {
        WorkerSpawn.killGroup(pid)
    }
}
