import AmeyaCore
import AppKit
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

    /// Set by SwiftUI views that can see `openWindow`; reopens the window after it was closed.
    var openMainWindow: (() -> Void)?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = results
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        autoConverter.applySettings()
        ClipboardActions.removeOldFiles()
        WheelController.shared.start() // The global drag wheel (Wheel/).
        if let ring = WheelController.previewRing(from: CommandLine.arguments) { WheelController.shared.showPreview(ring) }
        LaunchTiming.mark("finished launching")
        DispatchQueue.main.async { LaunchTiming.mark("first run loop turn") }
    }

    /// Dock drop and "Open With". The system grants the sandbox access to these files.
    func application(_ application: NSApplication, open urls: [URL]) {
        receive(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
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
        ClipboardActions.convertClipboard()
    }

    /// Menu bar → "Welcome Tour…": shows the first-launch tour again.
    func showWelcomeTour() {
        UserDefaults.standard.set(false, forKey: Preferences.hasSeenOnboardingKey)
        showMainWindow()
    }

    func showMainWindow() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        NSApp.activate()
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
