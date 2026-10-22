import AppKit
import SwiftUI

/// The big window and the Settings window, made only when they're opened and let go when they
/// close, so a menu bar Ameya keeps no window, view tree or thumbnail around while idle.
@MainActor
final class HostedWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let identifier: String
    private let title: String
    private let autosaveName: String
    private let minSize: NSSize
    private let makeContent: () -> NSViewController
    /// Called after the window closed and was released.
    var didClose: (() -> Void)?

    init(identifier: String, title: String, autosaveName: String, minSize: NSSize,
         makeContent: @escaping () -> NSViewController) {
        self.identifier = identifier
        self.title = title
        self.autosaveName = autosaveName
        self.minSize = minSize
        self.makeContent = makeContent
    }

    var isOpen: Bool { window != nil }
    var nsWindow: NSWindow? { window }

    /// Shows the window (making it first if needed). `activate: false` brings it forward without
    /// taking focus from the app the user is in.
    func show(activate: Bool = true) {
        let window = self.window ?? make()
        self.window = window
        if activate {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            window.orderFrontRegardless()
        }
    }

    func close() {
        window?.close()
    }

    private func make() -> NSWindow {
        let controller = makeContent()
        let window = NSWindow(contentViewController: controller)
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = minSize
        window.delegate = self
        if !window.setFrameUsingName(autosaveName) { window.center() }
        window.setFrameAutosaveName(autosaveName)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        // Let the SwiftUI tree (and its thumbnails) go once AppKit is done with the window.
        DispatchQueue.main.async { [weak self] in
            closing.contentViewController = nil
            closing.delegate = nil
            if self?.window === closing { self?.window = nil }
            self?.didClose?()
        }
    }
}

/// Whether Ameya shows a Dock icon. Off by default: Ameya lives in the menu bar (`LSUIElement`).
enum DockIcon {
    static let key = "showInDock"

    static var isShown: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Applies the setting. Keeps Ameya's open windows in front when the icon goes away.
    @MainActor
    static func apply() {
        let policy: NSApplication.ActivationPolicy = isShown ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            DispatchQueue.main.async { NSApp.activate() }
        }
    }
}
