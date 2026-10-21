import Darwin
import Foundation

/// How much memory and disk one job may use before it is stopped. A hostile or broken file can
/// make a decoder allocate without end or an encoder write without end; each job is checked
/// about four times a second and its whole process group is killed above either ceiling.
public struct WorkerLimits: Sendable, Equatable {
    /// Ceiling on the physical footprint of the worker and its helpers together.
    public var memoryBytes: UInt64
    /// Ceiling on the size of the output being written.
    public var outputBytes: Int64
    /// Stop when the output's disk has less than this left.
    public var reserveFreeBytes: Int64 = 256 << 20
    public var sampleInterval: Duration = .milliseconds(250)

    public init(memoryBytes: UInt64, outputBytes: Int64) {
        self.memoryBytes = memoryBytes
        self.outputBytes = outputBytes
    }

    /// No ceiling (only for callers that measure something else).
    public static let unlimited = WorkerLimits(memoryBytes: .max, outputBytes: .max)

    /// The default for a job over `families` whose inputs total `inputBytes`.
    ///
    /// Memory: min(6 GB, half the Mac's RAM); small text-like families get at most 2 GB.
    /// Output: max(2 GB, 20× the input) for most; video max(20 GB, 20×); audio max(4 GB, 40×)
    /// (compressed audio to WAV); archives and decompression max(8 GB, 100×).
    public static func forJob(families: [FileFormat.Family], inputBytes: Int64,
                              physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> WorkerLimits {
        let standard = min(6 << 30, physicalMemory / 2)
        let memory = families.map { family -> UInt64 in
            switch family {
            case .subtitle, .contacts, .geo: min(2 << 30, standard)
            default: standard
            }
        }.max() ?? standard
        let input = max(0, inputBytes)
        let output = families.map { family -> Int64 in
            switch family {
            case .video: max(20 << 30, input.multipliedClamped(by: 20))
            case .audio: max(4 << 30, input.multipliedClamped(by: 40))
            case .archive, .compressed: max(8 << 30, input.multipliedClamped(by: 100))
            default: max(2 << 30, input.multipliedClamped(by: 20))
            }
        }.max() ?? max(2 << 30, input.multipliedClamped(by: 20))
        return WorkerLimits(memoryBytes: memory, outputBytes: output)
    }

    /// Space a job needs free before it starts: twice the input plus 1 GB.
    public static func requiredFreeBytes(inputBytes: Int64) -> Int64 {
        max(0, inputBytes).multipliedClamped(by: 2) + (1 << 30)
    }

    /// Free bytes on the volume holding `folder` (space an app may use), or nil if unknown.
    public static func freeBytes(at folder: URL) -> Int64? {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        if let available = values?.volumeAvailableCapacity { return Int64(available) }
        var stats = statfs()
        guard statfs(folder.path, &stats) == 0 else { return nil }
        return Int64(stats.f_bavail) * Int64(stats.f_bsize)
    }

    /// Free bytes on the volume of an open file.
    static func freeBytes(descriptor: Int32) -> Int64? {
        var stats = statfs()
        guard fstatfs(descriptor, &stats) == 0 else { return nil }
        return Int64(stats.f_bavail) * Int64(stats.f_bsize)
    }

    /// Current size of an open file.
    static func size(descriptor: Int32) -> Int64 {
        var info = stat()
        return fstat(descriptor, &info) == 0 ? Int64(info.st_size) : 0
    }
}

extension Int64 {
    func multipliedClamped(by factor: Int64) -> Int64 {
        let (product, overflow) = multipliedReportingOverflow(by: factor)
        return overflow ? .max : product
    }
}

/// Removes what killed jobs leave behind: hidden `.<name>.<uuid>.partial` outputs and
/// `ameya-worker-<pid>-<uuid>` scratch folders.
public enum LeftoverSweeper {
    /// Partial outputs younger than this are left alone (another Ameya process may be writing them).
    public static let partialAge: TimeInterval = 60

    /// `.<name>.<UUID>.partial`, as `WorkerRunner` names them.
    public static func isPartialName(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".partial") else { return false }
        let stem = name.dropFirst().dropLast(".partial".count)
        guard let dot = stem.lastIndex(of: ".") else { return false }
        return UUID(uuidString: String(stem[stem.index(after: dot)...])) != nil && dot > stem.startIndex
    }

    /// Removes stale partial outputs in `folder`, never one a job in this process is writing.
    /// Returns how many were removed.
    @discardableResult
    public static func removePartials(in folder: URL, now: Date = Date(),
                                      isActive: (URL) -> Bool = WorkerRunner.isActivePartial) -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var removed = 0
        for entry in entries where isPartialName(entry.lastPathComponent) && !isActive(entry) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > partialAge else { continue }
            if (try? FileManager.default.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }

    /// The pid in an `ameya-worker-<pid>-<uuid>` folder name.
    public static func scratchOwner(_ name: String) -> pid_t? {
        guard name.hasPrefix("ameya-worker-") else { return nil }
        let rest = name.dropFirst("ameya-worker-".count)
        guard let dash = rest.firstIndex(of: "-"), let pid = Int32(rest[..<dash]), pid > 0 else { return nil }
        return pid
    }

    /// Removes scratch folders in `folder` whose worker is no longer running (or that are a day old).
    @discardableResult
    public static func removeScratchFolders(in folder: URL, now: Date = Date()) -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var removed = 0
        for entry in entries {
            guard let pid = scratchOwner(entry.lastPathComponent) else { continue }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let age = now.timeIntervalSince(modified)
            let gone = kill(pid, 0) == -1 && errno == ESRCH
            guard (gone && age > 60) || age > 24 * 3600 else { continue }
            if (try? FileManager.default.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }
}
