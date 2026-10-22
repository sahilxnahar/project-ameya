import AmeyaCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window: General, Keyboard & Mouse, Menu, with Import, Export and Reset below.
struct SettingsRoot: View {
    enum Tab: String, CaseIterable { case general, keyboard, menu }

    @State private var tab: Tab = .general
    @State private var message: String?
    @State private var confirmingReset = false
    /// Bumped after import or reset, so every tab reloads what it shows.
    @State private var generation = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                ScrollView { SettingsView() }
                    .tabItem { Label("General", systemImage: "gearshape") }
                    .tag(Tab.general)
                KeyboardMouseSettings()
                    .tabItem { Label("Keyboard & Mouse", systemImage: "keyboard") }
                    .tag(Tab.keyboard)
                MenuSettings()
                    .tabItem { Label("Menu", systemImage: "menubar.rectangle") }
                    .tag(Tab.menu)
            }
            .id(generation)
            Divider()
            HStack(spacing: 10) {
                Button("Import Settings…", action: importSettings)
                    .accessibilityHint("Opens an Ameya settings file you exported before.")
                Button("Export Settings…", action: exportSettings)
                    .accessibilityHint("Saves your settings as a small file you can keep or move to another Mac.")
                Spacer()
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Button("Reset to Defaults…") { confirmingReset = true }
                    .accessibilityHint("Puts every setting back the way Ameya came. Your files and Recent list stay.")
            }
            .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 420, idealHeight: 680)
        .tint(Theme.accent)
        .confirmationDialog("Reset every setting?", isPresented: $confirmingReset) {
            Button("Reset to Defaults", role: .destructive, action: reset)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shortcuts, the drag wheel, the menu bar and everything in General go back to how Ameya came. Your files and Recent list stay.")
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Ameya Settings.json"
        panel.message = "Save your Ameya settings as a file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try SettingsArchive.export(SettingsKeys.currentValues(), schema: SettingsKeys.schema)
            try data.write(to: url, options: .atomic)
            show("Settings exported.")
        } catch {
            show("Couldn't export: \(error.localizedDescription)")
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an Ameya settings file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let (values, ignored) = try SettingsArchive.read(data, schema: SettingsKeys.schema)
            SettingsKeys.removeAll()
            values.forEach { UserDefaults.standard.set($1, forKey: $0) }
            SettingsKeys.applyEverywhere()
            generation += 1
            show(ignored.isEmpty ? "Imported \(values.count) settings."
                                 : "Imported \(values.count) settings; left out \(ignored.count) Ameya doesn't know.")
        } catch {
            show((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func reset() {
        SettingsKeys.removeAll()
        SettingsKeys.applyEverywhere()
        generation += 1
        show("Settings are back to their defaults.")
    }

    private func show(_ text: String) {
        message = text
        Feedback.announce(text)
    }
}

/// Every setting that Export, Import and Reset cover, with its type. (The output folder isn't
/// included: it's a permission for one folder on this Mac, which a file can't carry.)
@MainActor
enum SettingsKeys {
    static let schema: [String: SettingKind] = [
        AutoConverter.enabledKey: .bool,
        AutoConverter.originalKey: .string,
        Preferences.playSoundsKey: .bool,
        Preferences.celebrateKey: .bool,
        "recentExpanded": .bool,
        WheelSettings.enabledKey: .bool,
        WheelSettings.sizeKey: .string,
        WheelSettings.excludedKey: .stringArray,
        WheelSettings.activationKey: .string,
        WheelSettings.delayKey: .double,
        "wheel.key.*": .string,
        "wheel.items.*": .stringArray,
        "hotkey.*": .string,
        DockIcon.key: .bool,
        QuickConvert.key: .bool,
        PanelPreferences.favouritesKey: .stringArray,
        PanelPreferences.densityKey: .string,
        PanelPreferences.largerTextKey: .bool,
        PanelPreferences.clickKey: .string,
        PanelPreferences.iconStyleKey: .string,
        PanelPreferences.dropActionKey: .string,
        "panel.show.*": .bool,
    ]

    /// The covered settings that are set now.
    static func currentValues() -> [String: Any] {
        UserDefaults.standard.dictionaryRepresentation().filter { SettingsArchive.kind(of: $0.key, in: schema) != nil }
    }

    static func removeAll() {
        currentValues().keys.forEach(UserDefaults.standard.removeObject(forKey:))
    }

    /// Settings read once at launch take effect now (the rest watch UserDefaults themselves).
    static func applyEverywhere() {
        DockIcon.apply()
        GlobalHotKey.shared.applySettings()
        AppDelegate.shared?.autoConverter.applySettings()
    }
}
