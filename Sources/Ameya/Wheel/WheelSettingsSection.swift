import AmeyaCore
import AppKit
import SwiftUI

/// Settings → "Drag wheel". Saved to UserDefaults; `WheelController` picks changes up at once.
struct WheelSettingsSection: View {
    @State private var settings = WheelSettings.load(from: .standard)

    var body: some View {
        Section("Drag wheel") {
            Toggle("Show the wheel when I hold a key while dragging files", isOn: binding(\.isEnabled))
                .accessibilityHint("While you drag files anywhere on the Mac, holding a key shows a wheel of things Ameya can do with them")

            Group {
                ForEach(WheelRing.allCases, id: \.self) { ring in
                    Picker(ring.title, selection: keyBinding(for: ring)) {
                        Text("No key").tag(WheelModifier?.none)
                        ForEach(WheelModifier.allCases, id: \.self) { key in
                            Text("\(key.symbol) \(key.title)").tag(WheelModifier?.some(key))
                        }
                    }
                    .accessibilityLabel("Key for the \(ring.title) wheel")
                }
                Picker("Wheel size", selection: binding(\.size)) {
                    ForEach(WheelSize.allCases, id: \.self) { size in Text(size.title).tag(size) }
                }
                .pickerStyle(.segmented)

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

    private func binding<Value>(_ keyPath: WritableKeyPath<WheelSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0; save() })
    }

    private func keyBinding(for ring: WheelRing) -> Binding<WheelModifier?> {
        Binding(get: { settings.mapping.key(for: ring) }, set: { key in
            settings.mapping = settings.mapping.assigning(key, to: ring)
            save()
        })
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
