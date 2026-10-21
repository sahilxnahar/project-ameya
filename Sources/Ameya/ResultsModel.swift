import AmeyaCore
import AppKit
import Combine
import Foundation

/// What happened to finished jobs: the batch headline, Recent (kept across launches), and Undo.
/// Created at launch so it hears about every job, including ones started from Finder's Services.
@MainActor
final class ResultsModel: ObservableObject {
    /// The latest batch's headline; `celebrations` goes up by one each time a batch finishes well.
    @Published private(set) var summary: BatchSummary?
    @Published private(set) var celebrations = 0
    @Published private(set) var recent: RecentList
    /// Jobs whose output was moved to the Trash with Undo.
    @Published private(set) var undone: Set<UUID> = []

    private let store: JobStore
    private let recentStore: RecentStore
    private var batch: [Job] = []
    private var subscription: AnyCancellable?

    init(store: JobStore, recentStore: RecentStore = .standard) {
        self.store = store
        self.recentStore = recentStore
        recent = recentStore.load()
        subscription = store.finished.sink { [weak self] job in self?.jobFinished(job) }
    }

    private func jobFinished(_ job: Job) {
        batch.append(job)
        if case .done(let result) = job.state {
            add(RecentFile(path: job.destination.path, bytesBefore: job.sourceBytes,
                           bytesAfter: Int64(result.outputBytes), isFolder: job.isFolder))
        }
        guard store.jobs.allSatisfy({ $0.state.isFinished }) else { return }
        let summary = BatchSummary(batch.map(\.outcome))
        batch = []
        guard summary.succeeded + summary.failed > 0 else { return }
        self.summary = summary
        Feedback.announce(summary.headline)
        if summary.isCelebration {
            celebrations += 1
            Feedback.play(.done)
        } else {
            Feedback.play(.problem)
        }
    }

    func dismissSummary() {
        summary = nil
    }

    // MARK: Undo

    func canUndo(_ job: Job) -> Bool {
        guard case .done(let result) = job.state, !undone.contains(job.id) else { return false }
        return Self.canUndo(job.destination, isFolder: job.isFolder, bytes: Int64(result.outputBytes))
    }

    func canUndo(_ file: RecentFile) -> Bool {
        Self.canUndo(file.url, isFolder: file.isFolder, bytes: file.bytesAfter)
    }

    private static func canUndo(_ url: URL, isFolder: Bool, bytes: Int64) -> Bool {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let size = isFolder ? nil : (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        return UndoCheck.canMoveToTrash(exists: exists, currentBytes: isFolder ? nil : (size ?? -1), recordedBytes: bytes)
    }

    /// Moves the output to the Trash (never deletes). Returns a problem to show, if any.
    @discardableResult
    func undo(_ job: Job) -> String? {
        guard canUndo(job) else { return "The file was moved or changed, so Ameya left it alone." }
        if let problem = moveToTrash(job.destination) { return problem }
        undone.insert(job.id)
        return nil
    }

    @discardableResult
    func undo(_ file: RecentFile) -> String? {
        guard canUndo(file) else { return "The file was moved or changed, so Ameya left it alone." }
        if let problem = moveToTrash(file.url) { return problem }
        if let job = store.jobs.first(where: { $0.destination.path == file.path }) { undone.insert(job.id) }
        return nil
    }

    private func moveToTrash(_ url: URL) -> String? {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            return "macOS couldn't move it to the Trash: \(error.localizedDescription)"
        }
        var list = recent
        list.remove(path: url.path)
        save(list)
        Feedback.announce("Moved \(url.lastPathComponent) to the Trash.")
        return nil
    }

    // MARK: Recent

    func clearRecent() {
        save(RecentList())
        Feedback.announce("Recent list cleared. Your files are still where they were.")
    }

    func exists(_ file: RecentFile) -> Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    private func add(_ file: RecentFile) {
        var list = recent
        list.add(file)
        save(list)
    }

    private func save(_ list: RecentList) {
        recent = list
        try? recentStore.save(list)
    }
}

extension Job {
    var outcome: BatchOutcome {
        switch state {
        case .done(let result):
            // A folder's reported size is a bundle of its files, not comparable to the source.
            isFolder ? .done(before: 0, after: 0) : .done(before: sourceBytes, after: Int64(result.outputBytes))
        case .failed: .failed
        case .cancelled, .queued, .running: .cancelled
        }
    }

    /// Before → after for a finished single-file output.
    var sizeChange: SizeChange? {
        guard case .done(let result) = state, !isFolder, sourceBytes > 0 else { return nil }
        return SizeChange(before: sourceBytes, after: Int64(result.outputBytes))
    }
}
