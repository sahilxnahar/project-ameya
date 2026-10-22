import AmeyaCore
import AppKit
import Darwin
import ImageIO

/// `Ameya --bench` measures the app's own costs on this Mac and prints them: setup of the
/// conversion matrix and tools, drop → job start, the per-job worker overhead (tiny files, where
/// the conversion itself is negligible), 50 real conversions, and memory before, during and after.
/// Everything happens in the sandbox's temp folder; Downloads and Recent are never touched.
@MainActor
enum Benchmark {
    static func run() async -> Bool {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ameya Bench", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let samples = folder.appendingPathComponent("samples", isDirectory: true)
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try? FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let big = (0..<50).compactMap { makePNG(in: samples, name: "photo \($0).png", width: 1600, height: 1000) }
        let tiny = (0..<10).compactMap { makePNG(in: samples, name: "tiny \($0).png", width: 16, height: 16) }
        guard big.count == 50, tiny.count == 10 else {
            print("BENCH FAILED: couldn't make sample files")
            return false
        }
        print("BENCH memory at start: \(Memory.summary)")

        var clock = ContinuousClock.now
        _ = FileFormat.systemWritable()
        print("BENCH systemWritable(): \(ms(since: clock)) ms")
        clock = .now
        let store = JobStore()
        print("BENCH JobStore() (matrix + tools): \(ms(since: clock)) ms")
        let results = ResultsModel(store: store, recentStore: RecentStore(url: folder.appendingPathComponent("recent.json")))
        _ = results

        // Drop → job start: what the app does between a drop and the worker being launched.
        clock = .now
        store.add([tiny[0]])
        _ = store.targets
        _ = store.tools
        let addMs = fmt(ms(since: clock))
        clock = .now
        let first = store.convertNow([tiny[0]], to: .jpeg, in: output)
        let startMs = fmt(ms(since: clock))
        await wait(for: first)
        store.clearPending()
        print("BENCH drop → choices shown: \(addMs) ms; choice → job running: \(startMs) ms")

        // Worker overhead: tiny files one after another, so each time is mostly process start-up.
        var times: [Double] = []
        for file in tiny {
            clock = .now
            let jobs = store.convertNow([file], to: .jpeg, in: output)
            await wait(for: jobs)
            times.append(ms(since: clock))
        }
        times.sort()
        print("BENCH per-job overhead (16×16 PNG → JPEG): median \(fmt(times[times.count / 2])) ms, min \(fmt(times[0])) ms")
        store.clearFinished()

        // 50 real files, as a batch.
        clock = .now
        let jobs = store.convertNow(big, to: .jpeg, in: output)
        await wait(for: jobs)
        let total = ms(since: clock)
        let done = jobs.filter { if case .done = $0.state { true } else { false } }.count
        print("BENCH 50 × 1600×1000 PNG → JPEG: \(fmt(total)) ms total, \(fmt(total / 50)) ms per file, \(done)/50 done")
        for job in jobs where !job.state.isFinished || job.outcome == .failed {
            print("BENCH not done: \(job.sources[0].lastPathComponent): \(job.state)")
        }
        print("BENCH memory after 50 files: \(Memory.summary)")
        store.clearFinished()
        try? await Task.sleep(for: .milliseconds(500))
        print("BENCH memory after clearing the results: \(Memory.summary)")
        try? FileManager.default.removeItem(at: folder)
        print(done == 50 ? "BENCH OK" : "BENCH FAILED")
        return done == 50
    }

    private static func wait(for jobs: [Job]) async {
        for _ in 0..<30000 where !jobs.allSatisfy({ $0.state.isFinished }) {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func ms(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.1f", value) }

    private static func makePNG(in folder: URL, name: String, width: Int, height: Int) -> URL? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for band in 0..<8 {
            context.setFillColor(CGColor(red: 0.9, green: 0.1 * Double(band), blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: band * height / 8, width: width, height: height / 8 + 1))
        }
        guard let image = context.makeImage() else { return nil }
        let url = folder.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url : nil
    }
}

/// The process's memory, as Activity Monitor and `footprint` see it.
enum Memory {
    static var footprintBytes: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static var residentBytes: UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    static var summary: String {
        "footprint \(footprintBytes / 1_048_576) MB, resident \(residentBytes / 1_048_576) MB"
    }
}

/// `AMEYA_TIMING=1` prints how long after the process started each launch milestone happened.
enum LaunchTiming {
    static let isEnabled = ProcessInfo.processInfo.environment["AMEYA_TIMING"] == "1"

    static func mark(_ milestone: String) {
        guard isEnabled else { return }
        print("TIMING \(milestone): \(Int(millisecondsSinceProcessStart)) ms")
        fflush(stdout)
    }

    static var millisecondsSinceProcessStart: Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
        return (Date().timeIntervalSince1970 - started) * 1000
    }
}
