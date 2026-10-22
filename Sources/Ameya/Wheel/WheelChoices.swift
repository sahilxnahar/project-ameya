import AmeyaCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One wedge on the wheel.
struct WheelChoice: Identifiable, Equatable {
    enum Action: Equatable {
        case convert(FileFormat)
        case tool(id: String)
        case openInAmeya
        case copyPath
        case showInFinder
    }

    let action: Action
    let title: String
    let systemImage: String
    /// One sentence for VoiceOver: what dropping here does.
    let help: String

    var id: String {
        switch action {
        case let .convert(format): "convert.\(format.rawValue)"
        case let .tool(id): "tool.\(id)"
        case .openInAmeya: "action.open"
        case .copyPath: "action.copyPath"
        case .showInFinder: "action.showInFinder"
        }
    }
}

/// Builds each wheel's wedges for the dragged files, and carries out the one dropped on.
///
/// Every choice here also exists without the wheel, for keyboard and VoiceOver users:
/// Convert and Tools are in the main window; the Actions are the main window itself and the
/// menu bar's "Files in Ameya" menu (`WheelMenuItems`).
@MainActor
enum WheelChoices {
    /// The wedges for `ring`. `chosen` (Settings → Keyboard & Mouse) lists wedge ids in the
    /// user's order; those that suit the files are used, else Ameya picks as usual.
    static func make(_ ring: WheelRing, formats: [FileFormat], store: JobStore, chosen: [String]?) -> [WheelChoice] {
        let automatic = make(ring, formats: formats, store: store)
        guard let chosen, !chosen.isEmpty else { return automatic }
        let all = allChoices(ring, formats: formats, store: store)
        let picked = chosen.compactMap { id in all.first { $0.id == id } }.prefix(WheelTargetRanker.maxWedges)
        return picked.isEmpty ? automatic : Array(picked)
    }

    /// Every wedge `ring` could offer for these files, for Settings and for user-chosen wheels.
    static func allChoices(_ ring: WheelRing, formats: [FileFormat], store: JobStore) -> [WheelChoice] {
        let fileWord = formats.count == 1 ? "this file" : "these \(formats.count) files"
        switch ring {
        case .convert:
            return store.matrix.commonTargets(for: formats).map { format in
                WheelChoice(action: .convert(format), title: format.displayName, systemImage: symbol(for: format),
                            help: "Saves a \(format.displayName) copy of \(fileWord).")
            }
        case .tools:
            return store.catalog.available(for: formats).map { tool in
                WheelChoice(action: .tool(id: tool.id), title: tool.title, systemImage: tool.systemImage, help: tool.help)
            }
        case .actions:
            return make(.actions, formats: formats, store: store)
        }
    }

    static func make(_ ring: WheelRing, formats: [FileFormat], store: JobStore) -> [WheelChoice] {
        let fileWord = formats.count == 1 ? "this file" : "these \(formats.count) files"
        switch ring {
        case .convert:
            let available = store.matrix.commonTargets(for: formats)
            return WheelTargetRanker.top(available, for: formats).map { format in
                WheelChoice(action: .convert(format), title: format.displayName, systemImage: symbol(for: format),
                            help: "Saves a \(format.displayName) copy of \(fileWord).")
            }
        case .tools:
            return store.catalog.available(for: formats).prefix(WheelTargetRanker.maxWedges).map { tool in
                WheelChoice(action: .tool(id: tool.id), title: tool.title, systemImage: tool.systemImage, help: tool.help)
            }
        case .actions:
            return [
                WheelChoice(action: .openInAmeya, title: "Open in Ameya", systemImage: "macwindow",
                            help: "Opens the Ameya window with \(fileWord), to pick what to do."),
                WheelChoice(action: .copyPath, title: "Copy path", systemImage: "doc.on.clipboard",
                            help: "Copies where \(fileWord) \(formats.count == 1 ? "is" : "are") on the Mac, as text."),
                WheelChoice(action: .showInFinder, title: "Show in Finder", systemImage: "folder",
                            help: "Shows \(fileWord) in a Finder window."),
            ]
        }
    }

    /// Carries out `choice` on the dropped files. Returns what to announce to VoiceOver.
    @discardableResult
    static func perform(_ choice: WheelChoice, on urls: [URL], delegate: AppDelegate) -> String {
        let store = delegate.store
        let files = OpenedFiles.accepted(urls)
        guard !files.isEmpty else { return "No files to work with." }
        switch choice.action {
        case let .convert(format):
            let jobs = store.convertNow(files, to: format)
            if jobs.isEmpty {
                delegate.receive(files) // Let the user pick something that works.
                return "Ameya can't make \(format.displayName) from these files."
            }
            showProgress(delegate)
            return "Converting \(jobs.count == 1 ? "1 file" : "\(jobs.count) files") to \(format.displayName)."
        case let .tool(id):
            guard let tool = store.catalog.tools.first(where: { $0.id == id }) else { return "" }
            if tool.panel != nil {
                // Tools with settings need their sheet: open the window with the files instead.
                delegate.receive(files)
                return "\(tool.title): choose settings in the Ameya window."
            }
            let jobs = store.runNow(tool, on: files)
            if jobs.isEmpty {
                delegate.receive(files)
                return "\(tool.title) doesn't work on these files."
            }
            showProgress(delegate)
            return "\(tool.title): started."
        case .openInAmeya:
            delegate.receive(files)
            return "Opened in Ameya."
        case .copyPath:
            copyPaths(files)
            return files.count == 1 ? "Path copied." : "\(files.count) paths copied."
        case .showInFinder:
            NSWorkspace.shared.activateFileViewerSelecting(files)
            return "Shown in Finder."
        }
    }

    static func copyPaths(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// Brings the window forward, without taking focus from the app the user dragged from, so
    /// they can see the progress and where the result went.
    private static func showProgress(_ delegate: AppDelegate) {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.orderFrontRegardless()
        } else {
            delegate.openMainWindow?()
        }
    }

    static func symbol(for format: FileFormat) -> String {
        switch format.family {
        case .image: "photo"
        case .document: format == .pdf ? "doc.richtext" : "doc.text"
        case .audio: "waveform"
        case .video: "film"
        case .subtitle: "captions.bubble"
        case .archive: "archivebox"
        case .data: "tablecells"
        case .contacts: "person.crop.circle"
        case .geo: "map"
        case .model: "cube"
        case .compressed: "shippingbox"
        }
    }
}

/// Reads what is being dragged, from the drag pasteboard, before and at the drop.
@MainActor
enum WheelPasteboard {
    /// Pasteboard types the wheel accepts: files, and promised files (Mail attachments, Photos).
    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    static func hasFiles(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return types.contains(where: acceptedTypes.contains)
    }

    /// The dragged files' formats, guessed from their names and promised types. The sandbox
    /// can't open the files until they are dropped, so this never reads file contents.
    static func predictedFormats(_ pasteboard: NSPasteboard) -> [FileFormat] {
        let urls = fileURLs(pasteboard)
        if !urls.isEmpty {
            return WheelTargetRanker.predictedFormats(forFileNames: urls.map(\.lastPathComponent))
        }
        let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        return promises.flatMap(\.fileTypes).map(format(forType:))
    }

    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func format(forType identifier: String) -> FileFormat {
        if let exact = FileFormat.allCases.first(where: { $0.typeIdentifier == identifier }) { return exact }
        if let ext = UTType(identifier)?.preferredFilenameExtension, let format = FileFormat.fromExtension(ext) {
            return format
        }
        return .other
    }

    /// The dropped files. Promised files are written into a scratch folder first.
    static func receive(_ pasteboard: NSPasteboard, completion: @escaping @MainActor ([URL]) -> Void) {
        let urls = fileURLs(pasteboard)
        if !urls.isEmpty {
            completion(urls)
            return
        }
        let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        guard !promises.isEmpty else {
            completion([])
            return
        }
        // The "ameya-worker-" prefix lets `JobStore.removeStaleScratchFolders` tidy it up later.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ameya-worker-wheel-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let collector = PromiseCollector(expected: promises.reduce(0) { $0 + max(1, $1.fileTypes.count) },
                                         completion: completion)
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        for promise in promises {
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                collector.add(error == nil ? url : nil)
            }
        }
    }
}

/// Gathers promised files as they arrive and calls back once every promise has answered.
private final class PromiseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var urls: [URL] = []
    private let completion: @MainActor ([URL]) -> Void

    init(expected: Int, completion: @escaping @MainActor ([URL]) -> Void) {
        remaining = expected
        self.completion = completion
    }

    func add(_ url: URL?) {
        lock.lock()
        if let url { urls.append(url) }
        remaining -= 1
        let done = remaining <= 0
        let result = urls
        lock.unlock()
        guard done else { return }
        let completion = completion
        Task { @MainActor in completion(result) }
    }
}
