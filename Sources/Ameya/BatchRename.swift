import AmeyaCore
import AppKit
import Foundation

/// Applies batch-rename plans. Copies are the default; renaming in place needs a folder the user
/// granted in an Open panel, and can be undone. Nothing is ever overwritten: the planner adds
/// " 2" to clashing names, and every move or copy fails rather than replace a file.
@MainActor
enum RenameApplier {
    struct Outcome {
        var done = 0
        var failed: [String] = []
    }

    /// Writes renamed copies into `directory`. Copying doesn't read the files' contents.
    static func copy(_ files: [URL], as names: [String], into directory: URL) -> Outcome {
        var outcome = Outcome()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (file, name) in zip(files, names) {
            do {
                try FileManager.default.copyItem(at: file, to: directory.appendingPathComponent(name))
                outcome.done += 1
            } catch {
                outcome.failed.append(file.lastPathComponent)
            }
        }
        return outcome
    }

    /// Renames the files where they are, in two steps (to hidden temporary names, then to the new
    /// names) so swapping names within the batch never overwrites anything. Records undo.
    static func renameInPlace(_ files: [URL], as names: [String], grantedFolder: URL) -> Outcome {
        var outcome = Outcome()
        var staged: [(original: URL, temporary: URL, final: URL)] = []
        for (file, name) in zip(files, names) where file.lastPathComponent != name {
            let temporary = file.deletingLastPathComponent().appendingPathComponent(".ameya-rename-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: file, to: temporary)
                staged.append((file, temporary, file.deletingLastPathComponent().appendingPathComponent(name)))
            } catch {
                outcome.failed.append(file.lastPathComponent)
            }
        }
        var moves: [RenameHistory.Move] = []
        for item in staged {
            do {
                try FileManager.default.moveItem(at: item.temporary, to: item.final) // fails if the name is taken
                moves.append(.init(from: item.original, to: item.final))
                outcome.done += 1
            } catch {
                try? FileManager.default.moveItem(at: item.temporary, to: item.original)
                outcome.failed.append(item.original.lastPathComponent)
            }
        }
        RenameHistory.shared.record(moves, folder: grantedFolder)
        return outcome
    }

    /// Asks for access to the folder holding `files`, which the sandbox needs to rename in place.
    /// Returns the folder, already being accessed, or nil if the user picked something else.
    static func requestFolder(for files: [URL]) -> URL? {
        guard let parent = commonFolder(files) else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = parent
        panel.prompt = "Allow Renaming"
        panel.message = "To rename these files where they are, choose the folder they're in: \(parent.lastPathComponent)"
        guard panel.runModal() == .OK, let folder = panel.url, folder.standardizedFileURL == parent.standardizedFileURL else {
            return nil
        }
        _ = folder.startAccessingSecurityScopedResource()
        return folder
    }

    /// The one folder holding every file, or nil when they're in different folders.
    static func commonFolder(_ files: [URL]) -> URL? {
        let parents = Set(files.map { $0.deletingLastPathComponent().standardizedFileURL })
        return parents.count == 1 ? parents.first : nil
    }
}

/// The last in-place rename, so it can be undone while Ameya is open.
@MainActor
final class RenameHistory: ObservableObject {
    static let shared = RenameHistory()

    struct Move: Equatable {
        var from: URL
        var to: URL
    }

    @Published private(set) var last: [Move] = []
    private var folder: URL?

    func record(_ moves: [Move], folder: URL) {
        self.folder?.stopAccessingSecurityScopedResource()
        last = moves
        self.folder = folder
    }

    /// Puts the names back. A file whose old name has been taken in the meantime keeps its new name.
    @discardableResult
    func undo() -> RenameApplier.Outcome {
        var outcome = RenameApplier.Outcome()
        for move in last.reversed() {
            do {
                try FileManager.default.moveItem(at: move.to, to: move.from)
                outcome.done += 1
            } catch {
                outcome.failed.append(move.to.lastPathComponent)
            }
        }
        last = []
        folder?.stopAccessingSecurityScopedResource()
        folder = nil
        return outcome
    }
}
