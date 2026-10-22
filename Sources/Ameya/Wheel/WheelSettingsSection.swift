import AmeyaCore
import AppKit
import SwiftUI

/// Settings → Keyboard & Mouse → "Drag wheel". Saved to UserDefaults; `WheelController` picks
/// changes up at once. Every control is a standard, labelled control: Tab, Space and VoiceOver.
struct WheelSettingsSection: View {
    @State private var settings = WheelSettings.load(from: .standard)

    var body: some View {
        Section("Drag wheel") {
            Toggle("Show the wheel when I hold keys while dragging files", isOn: binding(\.isEnabled))
                .accessibilityHint("While you drag files anywhere on the Mac, holding keys shows a wheel of things Ameya can do with them")

            Group {
                ForEach(WheelRing.allCases, id: \.self) { ring in
                    triggerRow(ring)
                }
                ForEach(Array(settings.mapping.conflicts.enumerated()), id: \.offset) { _, conflict in
                    Label(conflict.message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Keys count", selection: binding(\.activation)) {
                    ForEach(WheelActivation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .accessibilityHint("Choose whether pressing the keys during a drag opens the wheel, or only holding them as the drag starts")
                LabeledContent("Delay before showing") {
                    HStack {
                        Slider(value: binding(\.showDelay), in: 0...WheelSettings.maxDelay, step: 0.1)
                            .frame(width: 160)
                            .accessibilityLabel("Delay before the wheel shows")
                            .accessibilityValue(delayText)
                        Text(delayText).monospacedDigit().frame(width: 64, alignment: .leading)
                    }
                }
                Picker("Wheel size", selection: binding(\.size)) {
                    ForEach(WheelSize.allCases, id: \.self) { size in Text(size.title).tag(size) }
                }
                .pickerStyle(.segmented)

                // Ids distinct from the key rows above, so SwiftUI doesn't mix the two lists up.
                ForEach(WheelRing.allCases.map { "items.\($0.rawValue)" }, id: \.self) { id in
                    let ring = WheelRing(rawValue: String(id.dropFirst(6)))!
                    DisclosureGroup("What the \(ring.title) wheel shows") {
                        OrderedItemsEditor(noun: "wedge", all: SettingsCatalog.wedges(ring), chosen: itemsBinding(ring),
                                           emptyText: "Ameya picks the likeliest choices for the files you drag.")
                            .padding(.vertical, 4)
                    }
                }

                LabeledContent("Don't show the wheel in") {
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(settings.exclusions.bundleIDs, id: \.self) { id in
                            ExcludedAppRow(bundleID: id) {
                                settings.exclusions = settings.exclusions.removing(id)
                                save()
                            }
                        }
                        Button("Add Application…", action: addApplication)
                            .accessibilityHint("Pick an app, such as a design or CAD app, that uses modifier keys while dragging")
                    }
                }
                Text("Drop on a choice to use it; drop anywhere else or press Escape to leave the drag alone. Everything on the wheel is also in the Ameya window and menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.isEnabled)
        }
    }

    private var delayText: String {
        settings.showDelay == 0 ? "None" : String(format: "%.1f s", settings.showDelay)
    }

    /// One toggle per key (⌃ ⌥ ⇧ ⌘ fn): any single key or combination, or none for "off".
    private func triggerRow(_ ring: WheelRing) -> some View {
        let trigger = settings.mapping.trigger(for: ring)
        return LabeledContent {
            HStack(spacing: 4) {
                ForEach(WheelModifier.allCases, id: \.self) { key in
                    let isOn = trigger?.modifiers.contains(key) ?? false
                    let button = Button {
                        var keys = trigger?.modifiers ?? []
                        if isOn { keys.remove(key) } else { keys.insert(key) }
                        settings.mapping = settings.mapping.assigning(trigger: WheelTrigger(keys), to: ring)
                        save()
                    } label: {
                        Text(key.symbol).frame(minWidth: 18)
                    }
                    .help(key.title)
                    .accessibilityLabel("\(key.title) for the \(ring.title) wheel")
                    .accessibilityValue(isOn ? "on" : "off")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    // On: filled gold. Off: plain. Shape and fill differ, not only colour.
                    if isOn { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
                }
                Text(trigger.map { "= \($0.symbols)" } ?? "Off")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52, alignment: .leading)
                    .accessibilityHidden(true)
            }
        } label: {
            Text(ring.title)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keys for the \(ring.title) wheel: \(trigger?.title ?? "off")")
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<WheelSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0; save() })
    }

    private func itemsBinding(_ ring: WheelRing) -> Binding<[String]> {
        Binding(get: { settings.items[ring] ?? [] }, set: { settings.items[ring] = $0.isEmpty ? nil : $0; save() })
    }

    private func save() {
        settings.save(to: .standard)
    }

    private func addApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Don't Show Here"
        panel.message = "Choose apps where holding a key while dragging should never show the wheel."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier {
                settings.exclusions = settings.exclusions.adding(id)
            }
        }
        save()
    }
}

/// An excluded app, shown by name and icon, with a remove button.
private struct ExcludedAppRow: View {
    let bundleID: String
    let remove: () -> Void

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
        HStack(spacing: 6) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }
            Text(name.replacingOccurrences(of: ".app", with: ""))
            Button(action: remove) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Show the wheel in \(name) again")
        }
    }
}

/// Menu bar → "Files in Ameya": the wheel's Actions for the files waiting in the window, so
/// they are reachable from the keyboard and VoiceOver without dragging.
struct WheelMenuItems: View {
    @EnvironmentObject private var store: JobStore

    var body: some View {
        Menu("Files in Ameya") {
            Button("Copy Paths") { WheelChoices.copyPaths(store.pending.map(\.url)) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(store.pending.map(\.url)) }
        }
        .disabled(store.pending.isEmpty)
    }
}
