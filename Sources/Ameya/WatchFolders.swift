import AmeyaCore
import Combine
import Foundation

/// Watched folders (Settings › Watch folders): new files that arrive while Ameya runs are
/// converted, or put through a recipe. Files already there are never touched, and originals stay
/// put unless the user chose "Move to the Trash" for that folder.
///
/// Replaces the old Downloads HEIC → JPEG auto-converter, whose setting becomes the first rule.
@MainActor
final class WatchFolders: ObservableObject {
    @Published private(set) var rules: [WatchRule]
    @Published private(set) var isPaused: Bool
    /// Jobs started by watched folders that haven't finished yet (shown in the menu bar).
    @Published private(set) var activeCount = 0
    /// Rules whose folder couldn't be opened, with a plain reason.
    @Published private(set) var problems: [UUID: String] = [:]

    private let store: JobStore
    private let recipes: RecipeLibrary
    private let defaults: UserDefaults
    private var watchers: [UUID: FolderWatcher] = [:]
    private var watching: [UUID: AnyCancellable] = [:]

    init(store: JobStore, recipes: RecipeLibrary, defaults: UserDefaults = .standard) {
        self.store = store
        self.recipes = recipes
        self.defaults = defaults
        rules = WatchRules.load(from: defaults)
        isPaused = defaults.bool(forKey: WatchRules.pausedKey)
        WatchRules.save(rules, to: defaults)
    }

    var enabledCount: Int { rules.filter(\.isEnabled).count }

    func start() { apply() }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        defaults.set(paused, forKey: WatchRules.pausedKey)
        apply()
    }

    func update(_ rule: WatchRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule } else { rules.append(rule) }
        saveAndApply()
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        saveAndApply()
    }

    private func saveAndApply() {
        WatchRules.save(rules, to: defaults)
        apply()
    }

    /// Restarts watching to match the rules. Watchers for unchanged rules keep their state, so
    /// files that arrived before are not converted twice.
    private func apply() {
        let wanted = isPaused ? [] : rules.filter(\.isEnabled)
        for (id, watcher) in watchers where !wanted.contains(where: { $0.id == id && $0 == watcher.rule }) {
            watcher.stop()
            watchers[id] = nil
        }
        var problems: [UUID: String] = [:]
        for rule in wanted where watchers[rule.id] == nil {
            guard let folder = resolve(rule) else {
                problems[rule.id] = "Ameya can no longer open \(rule.folder.name). Choose the folder again."
                continue
            }
            let watcher = FolderWatcher(rule: rule, folder: folder) { [weak self] ready in
                self?.handle(ready, rule: rule, folder: folder)
            }
            if watcher.start() {
                watchers[rule.id] = watcher
            } else {
                problems[rule.id] = "Ameya can't watch \(rule.folder.name) right now."
            }
        }
        self.problems = problems
    }

    /// The folder's URL, with sandbox access started for picked folders.
    private func resolve(_ rule: WatchRule) -> URL? {
        switch rule.folder {
        case .downloads:
            return JobStore.realDownloadsDirectory()
        case let .picked(bookmark, name):
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { return nil }
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope]),
               let index = rules.firstIndex(where: { $0.id == rule.id }) {
                rules[index].folder = .picked(bookmark: fresh, name: name)
                WatchRules.save(rules, to: defaults)
            }
            return url
        }
    }

    private func handle(_ ready: [URL], rule: WatchRule, folder: URL) {
        let files = ready.filter { url in
            FileFormat.detectForConversion(at: url).map(rule.applies(to:)) ?? false
        }
        guard !files.isEmpty else { return }
        let directory: URL? = rule.output == .nextToOriginals ? folder : nil
        let jobs: [Job]
        switch rule.action {
        case let .convert(target):
            jobs = store.convertNow(files, to: target, in: directory)
        case let .recipe(id):
            guard let recipe = recipes.recipe(id: id),
                  let tool = store.catalog.tools.first(where: { $0.id == recipe.toolID }) else {
                problems[rule.id] = "The recipe for \(rule.folder.name) is missing or can't be used. Choose another."
                return
            }
            jobs = store.runNow(tool, on: files, in: directory)
        }
        integrationLog.info("Watch folder: \(jobs.count, privacy: .public) job(s) from \(files.count, privacy: .public) new file(s)")
        for job in jobs {
            // Never treat our own output as a new arrival, in any watched folder.
            watchers.values.forEach { $0.markProduced(job.destination) }
            activeCount += 1
            watching[job.id] = job.$state.sink { [weak self] state in
                guard state.isFinished else { return }
                if case .done = state, rule.original == .trash {
                    // Recoverable from the Trash; Ameya never deletes outright.
                    for source in job.sources { try? FileManager.default.trashItem(at: source, resultingItemURL: nil) }
                }
                Task { @MainActor in
                    guard let self, self.watching[job.id] != nil else { return }
                    self.watching[job.id] = nil
                    self.activeCount -= 1
                }
            }
        }
    }
}

/// Watches one folder: directory events are debounced, then new files are reported once their
/// size has settled (`StabilityTracker`).
@MainActor
final class FolderWatcher {
    let rule: WatchRule
    let folder: URL
    private let onReady: ([URL]) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var tracker: StabilityTracker
    private var debouncer = Debouncer(delay: 0.5)
    private var timer: Timer?

    init(rule: WatchRule, folder: URL, onReady: @escaping ([URL]) -> Void) {
        self.rule = rule
        self.folder = folder
        self.onReady = onReady
        tracker = rule.makeTracker()
    }

    func start() -> Bool {
        guard source == nil else { return true }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            integrationLog.error("Can't watch a folder (errno \(errno, privacy: .public))")
            return false
        }
        tracker.setBaseline(scan())
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .link], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
        timer?.invalidate()
        timer = nil
        if case .picked = rule.folder { folder.stopAccessingSecurityScopedResource() }
    }

    func markProduced(_ url: URL) { tracker.markProduced(url) }

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
        if !ready.isEmpty { onReady(ready) }
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
}
