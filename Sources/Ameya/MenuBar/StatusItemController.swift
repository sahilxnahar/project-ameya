import AmeyaCore
import AppKit
import Combine
import SwiftUI
import os

private let menuBarLog = Logger(subsystem: "io.github.sahilxnahar.ameya", category: "menubar")

/// Ameya's home: the menu bar icon, its panel, its right-click menu, and file drops onto it.
///
/// Light when idle: no timers and no polling. The icon only changes when a job reports
/// progress (throttled to 5 updates a second) or finishes. The panel's views are made when it
/// opens and let go when it closes.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let store: JobStore
    private let results: ResultsModel
    private let model = MenuBarModel()
    private let statusItem: NSStatusItem
    private var popover: NSPopover?
    private var dropView: StatusDropView?
    private var jobsSubscription: AnyCancellable?
    private var progressSubscription: AnyCancellable?
    private var finishedSubscription: AnyCancellable?
    /// Jobs that finished while the panel was closed; shown next to the icon until it opens.
    private var unseenFinished = 0
    private var showFinishedUntil: Date?
    private var look: StatusIcon.Look = .idle
    /// Only while the panel is open: closes it on clicks elsewhere and when Ameya loses focus.
    private var closeMonitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?

    /// Opens the big window. Set by the app delegate.
    var openWindow: () -> Void = {}
    var openSettings: () -> Void = {}

    init(store: JobStore, results: ResultsModel) {
        self.store = store
        self.results = results
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.autosaveName = "Ameya"
        configureButton()
        configureModel()
        observeJobs()
    }

    var isPanelShown: Bool { popover?.isShown == true }

    // MARK: Button

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = StatusIcon.image(.idle)
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Ameya")
        button.setAccessibilityHelp("Opens Ameya. Drop files here to convert them. Right-click for more.")
        button.toolTip = "Ameya: drop files here, or click"

        // Files dropped on the icon. A view over the button takes drags; the button's window is
        // registered too, in case the system routes the drag to the window rather than the view.
        let drop = StatusDropView(frame: button.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.onHover = { [weak self] hovering in self?.setDropHover(hovering) }
        drop.onDrop = { [weak self] urls in self?.receiveDrop(urls) }
        button.addSubview(drop)
        dropView = drop
        if let window = button.window, window.delegate == nil {
            window.registerForDraggedTypes(StatusDropView.types)
            window.delegate = drop
        }
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func setDropHover(_ hovering: Bool) {
        statusItem.button?.highlight(hovering)
        model.isDropTargeted = hovering
        updateIcon(hover: hovering)
    }

    private func receiveDrop(_ urls: [URL]) {
        let files = OpenedFiles.accepted(urls)
        let readable = files.allSatisfy { FileManager.default.isReadableFile(atPath: $0.path) }
        menuBarLog.info("Dropped on the menu bar: \(files.count, privacy: .public) file(s), readable: \(readable, privacy: .public)")
        LaunchTiming.mark("menu bar drop received")
        let before = store.pending.count
        store.add(files)
        let added = store.pending.count - before
        if added > 0 { Feedback.play(.added) }
        showPanel()
        Feedback.announce(added == 0 ? "Ameya can't convert these files."
                                     : added == 1 ? "Added 1 file. Pick what you want it to become."
                                                  : "Added \(added) files. Pick what you want them to become.")
    }

    // MARK: Panel

    private func configureModel() {
        model.close = { [weak self] in self?.closePanel() }
        model.openWindow = { [weak self] in
            self?.closePanel()
            self?.openWindow()
        }
        model.openSettings = { [weak self] in
            self?.closePanel()
            self?.openSettings()
        }
        model.chooseFiles = { [weak self] in self?.chooseFiles() }
    }

    func togglePanel() {
        if isPanelShown { closePanel() } else { showPanel() }
    }

    func showPanel() {
        guard let button = statusItem.button else { return }
        let started = ContinuousClock.now
        let popover = self.popover ?? makePopover()
        self.popover = popover
        if popover.contentViewController == nil { popover.contentViewController = makeContent() }
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        Self.activateApp()
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            watchForOutsideClicks()
        }
        popover.contentViewController?.view.window?.makeKey()
        let elapsed = (ContinuousClock.now - started).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        menuBarLog.info("Panel shown in \(ms, format: .fixed(precision: 1), privacy: .public) ms: \(popover.isShown, privacy: .public), app active: \(NSApp.isActive, privacy: .public)")
        unseenFinished = 0
        updateIcon()
        Feedback.announce(panelAnnouncement)
    }

    /// The panel takes the keyboard (search, Return, Escape), so Ameya has to become active.
    /// A menu bar app can't rely on cooperative activation: after a global shortcut nothing
    /// "hands over" focus, and a transient popover in an inactive app closes at once.
    static func activateApp() {
        NSRunningApplication.current.activate(options: [])
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    }

    func closePanel(reason: String = "asked") {
        guard popover?.isShown == true else { return }
        menuBarLog.info("Closing panel: \(reason, privacy: .public)")
        popover?.performClose(nil)
    }

    private var panelAnnouncement: String {
        let running = store.jobs.filter { !$0.state.isFinished }.count
        if running > 0 { return "Ameya. Converting \(running) file\(running == 1 ? "" : "s")." }
        if !store.pending.isEmpty { return "Ameya. \(store.pending.count) file\(store.pending.count == 1 ? "" : "s") ready." }
        return "Ameya. Drop files, or choose them."
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        // Closed by Ameya (`watchForOutsideClicks`) rather than by AppKit's "transient" rule,
        // which closes the panel at once whenever Ameya isn't the active app yet.
        popover.behavior = .applicationDefined
        popover.contentSize = MenuBarPanel.size
        popover.delegate = self
        return popover
    }

    private func makeContent() -> NSViewController {
        let root = MenuBarPanel()
            .environmentObject(store)
            .environmentObject(results)
            .environmentObject(model)
        let controller = PanelHostingController(rootView: AnyView(root))
        controller.onCancel = { [weak self] in self?.closePanel() }
        controller.preferredContentSize = MenuBarPanel.size
        return controller
    }

    private func watchForOutsideClicks() {
        stopWatchingClicks()
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel(reason: "click outside Ameya") }
        }) { closeMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let panelWindow = self.popover?.contentViewController?.view.window
                // Clicks in the panel stay; a click on the icon toggles it through the button.
                if event.window !== panelWindow, event.window !== self.statusItem.button?.window {
                    self.closePanel(reason: "click in another Ameya window")
                }
            }
            return event
        }) { closeMonitors.append(local) }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel(reason: "Ameya lost focus") }
        }
        // Activation finishes after `show`; then give the panel the keyboard (Escape, typing).
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover?.contentViewController?.view.window?.makeKey() }
        }
    }

    private func stopWatchingClicks() {
        closeMonitors.forEach(NSEvent.removeMonitor)
        closeMonitors = []
        for observer in [resignObserver, activeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        resignObserver = nil
        activeObserver = nil
    }

    func popoverDidClose(_ notification: Notification) {
        stopWatchingClicks()
        menuBarLog.info("Panel closed")
        // Nothing of the panel stays in memory while it's closed.
        popover?.contentViewController = nil
        model.isDropTargeted = false
    }

    /// The panel closes while the open panel is up, then comes back with the files.
    private func chooseFiles() {
        closePanel()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files for Ameya to convert."
        panel.prompt = "Add"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        store.add(panel.urls)
        showPanel()
    }

    // MARK: Right-click menu

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        buildMenu(menu)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil // Left clicks open the panel again.
    }

    private func buildMenu(_ menu: NSMenu) {
        menu.addItem(item("Open Panel", key: "") { [weak self] in self?.showPanel() })
        menu.addItem(item("Open Ameya Window", key: "n") { [weak self] in self?.openWindow() })
        menu.addItem(.separator())
        menu.addItem(item("Convert Clipboard…", key: "v") { ClipboardActions.convertClipboard() })
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

    // MARK: Progress on the icon

    private func observeJobs() {
        jobsSubscription = store.$jobs.sink { [weak self] jobs in
            // Runs before `jobs` changes; read the new value next turn.
            DispatchQueue.main.async { self?.watchRunning(jobs) }
        }
        finishedSubscription = store.finished.sink { [weak self] _ in
            DispatchQueue.main.async { self?.jobFinished() }
        }
    }

    private func watchRunning(_ jobs: [Job]) {
        let active = jobs.filter { !$0.state.isFinished }
        guard !active.isEmpty else {
            progressSubscription = nil
            updateIcon()
            return
        }
        progressSubscription = Publishers.MergeMany(active.map { $0.objectWillChange })
            .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateIcon() }
            }
        updateIcon()
    }

    private func jobFinished() {
        if !isPanelShown { unseenFinished += 1 }
        if store.jobs.allSatisfy({ $0.state.isFinished }) {
            progressSubscription = nil
            // A moment of "done": the fruit fills, then the count stays until the panel opens.
            let until = Date().addingTimeInterval(1.6)
            showFinishedUntil = until
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { [weak self] in
                guard let self, self.showFinishedUntil == until else { return }
                self.showFinishedUntil = nil
                self.updateIcon()
            }
        }
        updateIcon()
    }

    private func updateIcon(hover: Bool = false) {
        guard let button = statusItem.button else { return }
        let active = store.jobs.filter { !$0.state.isFinished }
        let next: StatusIcon.Look
        if hover || model.isDropTargeted {
            next = .dropTarget
        } else if !active.isEmpty {
            let fraction = active.map(\.progress).reduce(0, +) / Double(active.count)
            next = .working((fraction * 20).rounded() / 20) // 5% steps: fewer redraws.
        } else if showFinishedUntil != nil {
            next = .finished
        } else {
            next = .idle
        }
        if next != look {
            look = next
            button.image = StatusIcon.image(next)
        }
        let count = active.isEmpty ? unseenFinished : 0
        let title = count > 0 ? "\(count)" : ""
        if button.title != title {
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .baselineOffset: 0.5,
            ])
        }
        button.setAccessibilityValue(accessibilityValue(active: active, finished: count))
    }

    private func accessibilityValue(active: [Job], finished: Int) -> String {
        if !active.isEmpty {
            let percent = Int(active.map(\.progress).reduce(0, +) / Double(active.count) * 100)
            return "Converting \(active.count) file\(active.count == 1 ? "" : "s"), \(percent) percent"
        }
        if finished > 0 { return "\(finished) finished file\(finished == 1 ? "" : "s")" }
        if !store.pending.isEmpty { return "\(store.pending.count) file\(store.pending.count == 1 ? "" : "s") ready" }
        return ""
    }
}

/// Escape closes the panel (a search field takes Escape first, to clear itself).
private final class PanelHostingController: NSHostingController<AnyView> {
    var onCancel: () -> Void = {}

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
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
