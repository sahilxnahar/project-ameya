import AmeyaCore
import AppKit

/// The menu bar icon's menu, and the actions behind global shortcuts and drops on the icon.
extension StatusItemController {
    func buildMenu(_ menu: NSMenu) {
        menu.addItem(item("Open Panel", key: "") { [weak self] in self?.showPanel() })
        menu.addItem(item("Open Ameya Window", key: "n") { [weak self] in self?.openWindow() })
        menu.addItem(.separator())
        menu.addItem(item("Convert Clipboard…", key: "v") { [weak self] in self?.addClipboardAndShowPanel() })
        let copy = NSMenu()
        for (title, format) in [("JPEG", FileFormat.jpeg), ("PNG", .png), ("PDF", .pdf)] {
            copy.addItem(item(title, key: "") { ClipboardActions.copy(as: format) })
        }
        menu.addItem(submenu("Copy Clipboard Picture As", copy))
        let files = NSMenu()
        let pending = store.pending.map(\.url)
        files.addItem(item("Copy Paths", key: "") { WheelChoices.copyPaths(pending) })
        files.addItem(item("Show in Finder", key: "") { NSWorkspace.shared.activateFileViewerSelecting(pending) })
        let filesItem = submenu("Files in Ameya", files)
        filesItem.isEnabled = !pending.isEmpty
        menu.addItem(filesItem)
        menu.addItem(.separator())
        menu.addItem(submenu("Recent", recentMenu()))
        menu.addItem(item("Show Converted Files", key: "") { [store] in
            try? FileManager.default.createDirectory(at: store.outputDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(store.outputDirectory)
        })
        menu.addItem(.separator())
        menu.addItem(item("Welcome Tour…", key: "") { AppDelegate.shared?.showWelcomeTour() })
        menu.addItem(item("Settings…", key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(item("Quit Ameya", key: "q") { NSApp.terminate(nil) })
    }

    private func recentMenu() -> NSMenu {
        let menu = NSMenu()
        let recent = results.recent.items.prefix(8)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }
        for file in recent {
            let entry = item(file.name, key: "") { NSWorkspace.shared.open(file.url) }
            entry.isEnabled = results.exists(file)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("Clear Recent", key: "") { [results] in results.clearRecent() })
        return menu
    }

    private func item(_ title: String, key: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // MARK: Actions for shortcuts and drops

    /// Settings → Menu → "When files are dropped on the icon": runs a chosen format or tool at
    /// once. Returns false when it doesn't suit these files, so the panel asks instead.
    func runDropAction(_ id: String, on files: [URL]) -> Bool {
        guard let item = PanelItem.find(id, store: store) else { return false }
        let jobs: [Job]
        switch item.kind {
        case let .format(format):
            jobs = store.convertNow(files, to: format)
        case let .tool(toolID):
            guard let tool = store.catalog.tools.first(where: { $0.id == toolID }), tool.panel == nil else { return false }
            jobs = store.runNow(tool, on: files)
        }
        guard !jobs.isEmpty else { return false }
        Feedback.play(.added)
        Feedback.announce("\(item.title): started on \(jobs.count == 1 ? "1 file" : "\(jobs.count) files").")
        return true
    }

    /// Shortcut or menu: the clipboard's files or picture wait in the panel.
    func addClipboardAndShowPanel() {
        switch ClipboardActions.read() {
        case .files(let urls)?: store.add(urls)
        case .image(let url, _)?: store.add([url])
        case nil:
            Feedback.announce("There's no file or picture on the clipboard.")
            NSSound.beep()
            return
        }
        showPanel()
    }

    /// Shortcut: converts the waiting files, or else the clipboard's, to the last format used.
    func quickConvert() {
        guard let target = PanelPreferences.lastTarget else {
            Feedback.announce("Convert something first; this shortcut repeats the last format.")
            showPanel()
            return
        }
        if !store.pending.isEmpty, store.targets.contains(target) {
            let count = store.pending.count
            store.convert(to: target)
            Feedback.announce("Converting \(count == 1 ? "1 file" : "\(count) files") to \(target.displayName).")
            return
        }
        var files: [URL] = []
        switch ClipboardActions.read() {
        case .files(let urls)?: files = urls
        case .image(let url, _)?: files = [url]
        case nil: break
        }
        let jobs = files.isEmpty ? [] : store.convertNow(files, to: target)
        if jobs.isEmpty {
            Feedback.announce("Nothing waiting or on the clipboard can become \(target.displayName).")
            NSSound.beep()
            return
        }
        Feedback.announce("Converting \(jobs.count == 1 ? "1 file" : "\(jobs.count) files") to \(target.displayName).")
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
