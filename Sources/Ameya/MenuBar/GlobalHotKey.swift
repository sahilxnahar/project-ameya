import AppKit
import Carbon.HIToolbox
import os

private let hotKeyLog = Logger(subsystem: "io.github.sahilxnahar.ameya", category: "hotkey")

/// A keyboard shortcut that works from any app: Carbon's `RegisterEventHotKey`, which needs no
/// Accessibility permission and works in the sandbox. (A global `NSEvent` key monitor would
/// need Accessibility permission and could only watch, not take, the keystroke.)
struct HotKeyShortcut: Codable, Equatable {
    /// A virtual key code (`kVK_…`).
    var keyCode: UInt32
    /// Carbon modifier flags (`controlKey`, `optionKey`, `cmdKey`, `shiftKey`).
    var modifiers: UInt32
    /// What the key is called, e.g. "Space" or "A".
    var keyName: String

    static let standard = HotKeyShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), keyName: "Space")

    /// "⌃⌥Space".
    var symbols: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName
    }

    /// "Control Option Space", for VoiceOver.
    var spoken: String {
        var words: [String] = []
        if modifiers & UInt32(controlKey) != 0 { words.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { words.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { words.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { words.append("Command") }
        return (words + [keyName]).joined(separator: " ")
    }

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

/// Settings for the panel's shortcut, kept in UserDefaults.
enum HotKeySettings {
    static let shortcutKey = "menuBarHotKey"
    static let enabledKey = "menuBarHotKeyEnabled"

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static var shortcut: HotKeyShortcut {
        get {
            guard let data = UserDefaults.standard.data(forKey: shortcutKey),
                  let shortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: data) else { return .standard }
            return shortcut
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: shortcutKey) }
    }
}

/// Owns the one registered hot key. Costs nothing until the key is pressed: the system delivers it.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    /// Called on the main actor when the shortcut is pressed.
    var action: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x414D_5941 // "AMYA"

    private init() {}

    /// Registers the shortcut from Settings (or nothing when it's turned off).
    /// Returns a problem to show when another app already uses it.
    @discardableResult
    func applySettings() -> String? {
        register(HotKeySettings.isEnabled ? HotKeySettings.shortcut : nil)
    }

    @discardableResult
    func register(_ shortcut: HotKeyShortcut?) -> String? {
        unregister()
        guard let shortcut else { return nil }
        installHandlerIfNeeded()
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            hotKeyLog.error("Couldn't register \(shortcut.symbols, privacy: .public): \(status, privacy: .public)")
            return "\(shortcut.symbols) is already used by macOS or another app. Try a different shortcut."
        }
        hotKey = reference
        hotKeyLog.info("Shortcut \(shortcut.symbols, privacy: .public) registered")
        return nil
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            // Carbon calls this on the main thread.
            MainActor.assumeIsolated { GlobalHotKey.shared.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
