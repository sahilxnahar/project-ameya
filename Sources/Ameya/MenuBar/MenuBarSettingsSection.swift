import AppKit
import SwiftUI

/// Settings → "Menu bar": the Dock icon, the panel's keyboard shortcut and the quick HEIC button.
struct MenuBarSettingsSection: View {
    @AppStorage(DockIcon.key) private var showInDock = false
    @AppStorage(HotKeySettings.enabledKey) private var shortcutOn = true
    @AppStorage(QuickConvert.key) private var quickConvert = true
    @State private var shortcut = HotKeySettings.shortcut
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        Section("Menu bar") {
            Toggle("Show Ameya in the Dock", isOn: $showInDock)
                .accessibilityHint("Ameya always has its icon in the menu bar. This adds one to the Dock too.")
                .accessibilityIdentifier("settings-dock")
                .onChange(of: showInDock) { _, _ in DockIcon.apply() }

            Toggle("Open the panel from any app with a shortcut", isOn: $shortcutOn)
                .accessibilityIdentifier("settings-shortcut-on")
                .onChange(of: shortcutOn) { _, _ in problem = GlobalHotKey.shared.applySettings() }
            LabeledContent("Shortcut") {
                HStack(spacing: 8) {
                    Text(recording ? "Press keys…" : shortcut.symbols)
                        .font(.body.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(recording ? Theme.accent : Color.secondary.opacity(0.4)))
                        .accessibilityHidden(true)
                    Button(recording ? "Cancel" : "Change…") { recording ? stopRecording() : startRecording() }
                        .accessibilityLabel(recording ? "Cancel recording" : "Change shortcut, currently \(shortcut.spoken)")
                        .accessibilityHint(recording ? "" : "Then press the new keys, with Control, Option or Command.")
                        .accessibilityIdentifier("settings-shortcut-change")
                    if shortcut != .standard {
                        Button("Reset") { save(.standard) }
                            .accessibilityHint("Goes back to Control Option Space.")
                    }
                }
            }
            .disabled(!shortcutOn)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Offer one-click “Convert to JPEG” for iPhone photos", isOn: $quickConvert)
                .accessibilityHint("When every file you drop on the menu bar is a HEIC photo, a JPEG button comes first.")
                .accessibilityIdentifier("settings-quick-heic")
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        problem = nil
        recording = true
        Feedback.announce("Press the new shortcut, with Control, Option or Command. Escape cancels.")
        // Only while recording, and only for keys pressed in Settings.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stopRecording()
                return nil
            }
            guard let new = HotKeyShortcut(event: event) else {
                problem = "Include Control, Option or Command, so the shortcut doesn't get in the way of typing."
                return nil
            }
            save(new)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private func save(_ new: HotKeyShortcut) {
        HotKeySettings.shortcut = new
        shortcut = new
        problem = GlobalHotKey.shared.applySettings()
        if problem == nil { Feedback.announce("Shortcut set to \(new.spoken).") }
    }
}
