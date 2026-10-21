import AmeyaCore
import Combine
import Foundation

/// Watches the user's Downloads folder and turns new iPhone photos (HEIC) into JPEGs beside them.
/// Off by default. Only files that arrive while Ameya runs are converted, never ones already there.
@MainActor
final class AutoConverter {
    static let enabledKey = "autoConvertHEIC"
    static let originalKey = "heicOriginal"

    enum Original: String, CaseIterable, Identifiable {
        case keep
        case trash  // Recoverable from the Trash; Ameya never deletes outright.
        var id: String { rawValue }
    }

    private let store: JobStore
    private let folder = JobStore.realDownloadsDirectory()
    private var source: DispatchSourceFileSystemObject?
    private var tracker = StabilityTracker()
    private var debouncer = Debouncer(delay: 0.5)
    private var timer: Timer?
    private var watching: [UUID: AnyCancellable] = [:]

    init(store: JobStore) {
        self.store = store
    }

    var isRunning: Bool { source != nil }

    func applySettings() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { start() } else { stop() }
    }

    private func start() {
        guard source == nil else { return }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            integrationLog.error("Can't watch Downloads (errno \(errno, privacy: .public))")
            return
        }
        tracker = StabilityTracker()
        tracker.setBaseline(scan())
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .link], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        integrationLog.info("Watching Downloads for HEIC photos")
    }

    private func stop() {
        source?.cancel()
        source = nil
        timer?.invalidate()
        timer = nil
    }

    /// Directory events come in bursts while a download is created and renamed; wait for quiet.
    private func folderChanged() {
        schedule(at: debouncer.signal(at: Date()))
    }

    private func schedule(at date: Date) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(0.05, date.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard source != nil else { return }
        _ = debouncer.fire(at: Date())
        let ready = tracker.update(scan(), now: Date())
        if !ready.isEmpty { convert(ready) }
        // A growing file doesn't change the folder, so keep polling until candidates settle.
        if tracker.hasCandidates { schedule(at: Date().addingTimeInterval(1)) }
    }

    private func scan() -> [WatchedFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return WatchedFile(url: url, size: Int64(values.fileSize ?? 0))
        }
    }

    private func convert(_ files: [URL]) {
        let jobs = store.convertNow(files, to: .jpeg, in: folder)
        integrationLog.info("Auto-converting \(jobs.count, privacy: .public) HEIC photo(s)")
        let trash = Original(rawValue: UserDefaults.standard.string(forKey: Self.originalKey) ?? "") == .trash
        for job in jobs {
            tracker.markProduced(job.destination)
            guard trash else { continue }
            watching[job.id] = job.$state.sink { [weak self] state in
                guard state.isFinished else { return }
                if case .done = state {
                    for source in job.sources { try? FileManager.default.trashItem(at: source, resultingItemURL: nil) }
                }
                Task { @MainActor in self?.watching[job.id] = nil }
            }
        }
    }
}
