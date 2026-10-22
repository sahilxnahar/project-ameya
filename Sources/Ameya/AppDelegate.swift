import AmeyaCore
import AppKit
import ServiceManagement
import SwiftUI
import os

let integrationLog = Logger(subsystem: "io.github.sahilxnahar.ameya", category: "integration")

/// Files arriving from outside the window: "Open With", the Dock icon, Finder's Services menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    let store = JobStore()
    lazy var autoConverter = AutoConverter(store: store)
    /// Batch headlines, Recent and Undo. Made at launch so it hears about every job.
    lazy var results = ResultsModel(store: store)
    private let services = ServiceProvider()
    /// The menu bar icon and its panel (MenuBar/). Made at launch.
    private(set) var statusItem: StatusItemController?
    /// The big window, made when first opened and released when closed.
    private lazy var mainWindow = HostedWindow(
        identifier: "main", title: "Ameya", autosaveName: "AmeyaMainWindow", minSize: NSSize(width: 520, height: 500)
    ) { [unowned self] in
        NSHostingController(rootView: AnyView(MainView().environmentObject(store).environmentObject(results)))
    }
    private lazy var settingsWindow = HostedWindow(
        identifier: "settings", title: "Ameya Settings", autosaveName: "AmeyaSettingsWindow", minSize: NSSize(width: 560, height: 420)
    ) {
        // General, Keyboard & Mouse, Menu (Settings/).
        NSHostingController(rootView: SettingsRoot())
    }

    /// Reopens the window after it was closed. Kept for callers like the drag wheel.
    var openMainWindow: (() -> Void)?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Info.plist's LSUIElement hides the Dock icon; Settings can bring it back.
        if DockIcon.isShown { NSApp.setActivationPolicy(.regular) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = results
        let statusItem = StatusItemController(store: store, results: results)
        statusItem.openWindow = { [weak self] in self?.showMainWindow() }
        statusItem.openSettings = { [weak self] in self?.showSettings() }
        self.statusItem = statusItem
        openMainWindow = { [weak self] in self?.mainWindow.show() }
        LaunchTiming.mark("status item created")
        DispatchQueue.main.async { LaunchTiming.mark("status item on screen (first run loop turn)") }

        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        autoConverter.applySettings()
        ClipboardActions.removeOldFiles()
        GlobalHotKey.shared.handlers = [
            .openPanel: { [weak self] in self?.statusItem?.togglePanel() },
            .convertClipboard: { [weak self] in self?.statusItem?.addClipboardAndShowPanel() },
            .openWindow: { [weak self] in self?.showMainWindow() },
            .quickConvert: { [weak self] in self?.statusItem?.quickConvert() },
        ]
        GlobalHotKey.shared.applySettings()
        WheelController.shared.start() // The global drag wheel (Wheel/).
        if let ring = WheelController.previewRing(from: CommandLine.arguments) { WheelController.shared.showPreview(ring) }
        LaunchTiming.mark("finished launching")
        showSomethingAtLaunch()
    }

    /// First launch: the window with the welcome tour. Later, when the user opened Ameya
    /// themselves (not at login), the panel, so it's clear where Ameya lives.
    private func showSomethingAtLaunch() {
        guard !LaunchTiming.isEnabled, WheelController.previewRing(from: CommandLine.arguments) == nil else { return }
        if !UserDefaults.standard.bool(forKey: Preferences.hasSeenOnboardingKey) {
            showMainWindow()
        } else if SMAppService.mainApp.status != .enabled {
            // After the status item has been placed in the menu bar.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                // Unless files arrived with the launch and opened the window already.
                guard self?.mainWindow.isOpen == false else { return }
                self?.showPanel()
            }
        }
    }

    func showPanel() {
        statusItem?.showPanel()
    }

    func showSettings() {
        settingsWindow.show()
    }

    /// Dock drop and "Open With". The system grants the sandbox access to these files.
    func application(_ application: NSApplication, open urls: [URL]) {
        receive(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock icon click: the big window. Opening Ameya again from Finder or Spotlight while it
        // runs in the menu bar: the panel, where it lives.
        if !flag { DockIcon.isShown ? showMainWindow() : showPanel() }
        return true
    }

    /// Adds files as pending and brings the window forward so the user picks a format.
    func receive(_ urls: [URL]) {
        let files = OpenedFiles.accepted(urls)
        integrationLog.info("Received \(files.count, privacy: .public) file(s), readable: \(files.allSatisfy { FileManager.default.isReadableFile(atPath: $0.path) }, privacy: .public)")
        store.add(files)
        showMainWindow()
    }

    /// Edit → Paste (⌘V) when nothing focused takes it, e.g. a text field: adds the clipboard's
    /// files or picture. Reached through the responder chain, so text fields keep normal paste.
    @objc func paste(_ sender: Any?) {
        if statusItem?.isPanelShown == true, let content = ClipboardActions.read() {
            // The panel is open: add the clipboard there instead of opening the window.
            switch content {
            case .files(let urls): store.add(urls)
            case .image(let url, _): store.add([url])
            }
            return
        }
        ClipboardActions.convertClipboard()
    }

    /// Menu bar → "Welcome Tour…": shows the first-launch tour again.
    func showWelcomeTour() {
        UserDefaults.standard.set(false, forKey: Preferences.hasSeenOnboardingKey)
        showMainWindow()
    }

    func showMainWindow() {
        statusItem?.closePanel()
        mainWindow.show()
    }
}

/// Finder → right-click → Services. Selectors match `NSMessage` in Info.plist.
///
/// Files sent through a Services pasteboard come with sandbox extensions, like a drag and drop,
/// so the sandboxed app can read them (checked and logged in `AppDelegate.receive`).
@MainActor
final class ServiceProvider: NSObject {
    /// "Convert with Ameya": opens the window with the files ready to pick a format.
    @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = Self.fileURLs(on: pasteboard)
        guard !urls.isEmpty else {
            error.pointee = "There were no files to convert." as NSString
            return
        }
        AppDelegate.shared?.receive(urls)
    }

    /// "Convert to JPEG with Ameya": starts straight away, saving where Settings says.
    @objc func convertToJPEG(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = OpenedFiles.accepted(Self.fileURLs(on: pasteboard))
        guard let delegate = AppDelegate.shared else { return }
        let jobs = delegate.store.convertNow(urls, to: .jpeg)
        integrationLog.info("Service JPEG: \(urls.count, privacy: .public) file(s), \(jobs.count, privacy: .public) queued")
        if jobs.isEmpty { error.pointee = "Ameya can't make a JPEG from these files." as NSString }
        delegate.showMainWindow()
    }

    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
