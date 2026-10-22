import AppKit
import Carbon.HIToolbox
import os

private let hotKeyLog = Logger(subsystem: "io.github.sahilxnahar.ameya", category: "hotkey")

/// A keyboard shortcut that works from any app: Carbon's `RegisterEventHotKey`, which needs no
/// Accessibility permission and works in the sandbox. (A global `NSEvent` key monitor would
/// need Accessibility permission and could only watch, not take, the keystroke.)
struct HotKeyShortcut: Codable, Equatable, Hashable {
    /// A virtual key code (`kVK_…`).
    var keyCode: UInt32
    /// Carbon modifier flags (`controlKey`, `optionKey`, `cmdKey`, `shiftKey`).
    var modifiers: UInt32
    /// What the key is called, e.g. "Space" or "A".
    var keyName: String

    static let standard = HotKeyShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), keyName: "Space")

    private var parts: [(UInt32, String, String)] {
        [(UInt32(controlKey), "⌃", "Control"), (UInt32(optionKey), "⌥", "Option"),
         (UInt32(shiftKey), "⇧", "Shift"), (UInt32(cmdKey), "⌘", "Command")]
            .filter { modifiers & $0.0 != 0 }
    }

    /// "⌃⌥Space".
    var symbols: String { parts.map(\.1).joined() + keyName }
    /// "Control Option Space", for VoiceOver.
    var spoken: String { (parts.map(\.2) + [keyName]).joined(separator: " ") }

    /// A shortcut from a key press, or nil when it has no ⌃, ⌥ or ⌘ (plain keys would get in
    /// the way of typing everywhere).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        guard carbon & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon, keyName: Self.name(for: event))
    }

    init(keyCode: UInt32, modifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    private static func name(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_Escape: return "Escape"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            let characters = event.charactersIgnoringModifiers?.uppercased() ?? ""
            return characters.isEmpty || characters.unicodeScalars.contains(where: { $0.value < 32 }) ? "Key \(event.keyCode)" : characters
        }
    }
}

/// What a global shortcut does.
enum HotKeyAction: String, CaseIterable, Identifiable {
    case openPanel
    case convertClipboard
    case openWindow
    case quickConvert

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openPanel: "Open the menu bar panel"
        case .convertClipboard: "Convert what's on the clipboard"
        case .openWindow: "Open the Ameya window"
        case .quickConvert: "Convert again to the last format"
        }
    }

    var help: String {
        switch self {
        case .openPanel: "Shows Ameya's panel under its menu bar icon, ready for files."
        case .convertClipboard: "Adds the files or picture on the clipboard to Ameya, to pick a format."
        case .openWindow: "Opens the big Ameya window."
        case .quickConvert: "Converts the waiting files, or the clipboard's, to the format you used last."
        }
    }

    /// Only the panel has a shortcut out of the box.
    var standard: HotKeyShortcut? { self == .openPanel ? .standard : nil }
}

/// Shortcuts, kept in UserDefaults as JSON text ("none" when cleared on purpose).
enum HotKeySettings {
    static func key(_ action: HotKeyAction) -> String { "hotkey.\(action.rawValue)" }
    static let none = "none"

    static func shortcut(for action: HotKeyAction) -> HotKeyShortcut? {
        guard let text = UserDefaults.standard.string(forKey: key(action)) else { return action.standard }
        guard text != none, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HotKeyShortcut.self, from: data)
    }

    static func set(_ shortcut: HotKeyShortcut?, for action: HotKeyAction) {
        let text = shortcut.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        UserDefaults.standard.set(text ?? none, forKey: key(action))
    }

    static func reset(_ action: HotKeyAction) {
        UserDefaults.standard.removeObject(forKey: key(action))
    }
}

/// Owns the registered hot keys. Costs nothing until one is pressed: the system delivers it.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    /// Called on the main actor when an action's shortcut is pressed.
    var handlers: [HotKeyAction: () -> Void] = [:]
    private var registered: [HotKeyAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x414D_5941 // "AMYA"

    private init() {}

    /// While Settings records a shortcut, every shortcut is let go, so pressing one that's
    /// already in use reaches the recorder instead of running its action.
    var handlersPaused = false {
        didSet {
            guard handlersPaused != oldValue else { return }
            if handlersPaused {
                registered.values.forEach { UnregisterEventHotKey($0) }
                registered = [:]
            } else {
                applySettings()
            }
        }
    }

    /// Registers every shortcut from Settings. Returns, per action, a problem to show when
    /// macOS or another app already uses that shortcut.
    @discardableResult
    func applySettings() -> [HotKeyAction: String] {
        guard !handlersPaused else { return [:] }
        registered.values.forEach { UnregisterEventHotKey($0) }
        registered = [:]
        installHandlerIfNeeded()
        var problems: [HotKeyAction: String] = [:]
        for (index, action) in HotKeyAction.allCases.enumerated() {
            guard let shortcut = HotKeySettings.shortcut(for: action) else { continue }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                             EventHotKeyID(signature: Self.signature, id: UInt32(index + 1)),
                                             GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                registered[action] = reference
            } else {
                hotKeyLog.error("Couldn't register \(shortcut.symbols, privacy: .public): \(status, privacy: .public)")
                problems[action] = "\(shortcut.symbols) is already taken by another app. Try a different shortcut."
            }
        }
        hotKeyLog.info("Registered \(self.registered.count, privacy: .public) shortcut(s)")
        return problems
    }

    fileprivate func fire(id: UInt32) {
        let actions = HotKeyAction.allCases
        guard id >= 1, Int(id) <= actions.count else { return }
        handlers[actions[Int(id) - 1]]?()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            // Carbon calls this on the main thread.
            MainActor.assumeIsolated { GlobalHotKey.shared.fire(id: id) }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

/// Shortcuts macOS uses out of the box, so the recorder can warn before they clash.
/// (A sandboxed app can't read the user's own System Settings › Keyboard › Shortcuts.)
enum SystemShortcuts {
    private static let ctrl = UInt32(controlKey), opt = UInt32(optionKey), cmd = UInt32(cmdKey), shift = UInt32(shiftKey)

    static let known: [(keyCode: Int, modifiers: UInt32, meaning: String)] = [
        (kVK_Space, cmd, "Spotlight"),
        (kVK_Space, cmd | opt, "Finder search window"),
        (kVK_Space, ctrl, "Select the previous input source"),
        (kVK_Space, ctrl | opt, "Select the next input source (when you have more than one keyboard language)"),
        (kVK_Space, ctrl | cmd, "Emoji & Symbols"),
        (kVK_Tab, cmd, "App Switcher"),
        (kVK_ANSI_3, cmd | shift, "Screenshot"),
        (kVK_ANSI_4, cmd | shift, "Screenshot of a selection"),
        (kVK_ANSI_5, cmd | shift, "Screenshot and recording options"),
        (kVK_ANSI_Q, ctrl | cmd, "Lock Screen"),
        (kVK_ANSI_Q, cmd | shift, "Log Out"),
        (kVK_Escape, cmd | opt, "Force Quit"),
        (kVK_ANSI_D, cmd | opt, "Show or hide the Dock"),
        (kVK_ANSI_F, ctrl | cmd, "Full Screen"),
        (kVK_UpArrow, ctrl, "Mission Control"),
        (kVK_DownArrow, ctrl, "Application windows"),
        (kVK_LeftArrow, ctrl, "Move one space left"),
        (kVK_RightArrow, ctrl, "Move one space right"),
        (kVK_ANSI_H, cmd, "Hide the frontmost app"),
        (kVK_ANSI_Q, cmd, "Quit the frontmost app"),
        (kVK_ANSI_W, cmd, "Close the window"),
        (kVK_ANSI_C, cmd, "Copy"),
        (kVK_ANSI_V, cmd, "Paste"),
        (kVK_ANSI_X, cmd, "Cut"),
        (kVK_ANSI_Z, cmd, "Undo"),
        (kVK_ANSI_A, cmd, "Select All"),
        (kVK_ANSI_N, cmd, "New window or document in most apps"),
        (kVK_ANSI_O, cmd, "Open in most apps"),
        (kVK_ANSI_S, cmd, "Save in most apps"),
        (kVK_ANSI_M, cmd, "Minimise the window"),
    ]

    /// What `shortcut` already does on a standard Mac, if anything.
    static func meaning(of shortcut: HotKeyShortcut) -> String? {
        known.first { $0.keyCode == Int(shortcut.keyCode) && $0.modifiers == shortcut.modifiers }?.meaning
    }
}
