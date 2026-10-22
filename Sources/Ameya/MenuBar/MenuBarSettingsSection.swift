import AppKit
import SwiftUI

/// Settings → Menu: the menu bar icon and its panel.
struct MenuSettings: View {
    @AppStorage(DockIcon.key) private var showInDock = false
    @AppStorage(PanelPreferences.iconStyleKey) private var iconStyle = StatusIcon.Style.progress.rawValue
    @AppStorage(PanelPreferences.clickKey) private var click = ClickBehaviour.leftOpensPanel.rawValue
    @AppStorage(PanelPreferences.dropActionKey) private var dropAction = "ask"
    @AppStorage(PanelPreferences.densityKey) private var density = PanelDensity.comfortable.rawValue
    @AppStorage(PanelPreferences.largerTextKey) private var largerText = false
    @AppStorage(QuickConvert.key) private var quickConvert = true
    @State private var favourites = PanelPreferences.favourites

    var body: some View {
        Form {
            Section("Menu bar icon") {
                Picker("Icon", selection: $iconStyle) {
                    ForEach(StatusIcon.Style.allCases) { style in
                        Label {
                            Text(style.title)
                        } icon: {
                            Image(nsImage: StatusIcon.image(style == .progress ? .working(0.6) : .idle, style: style))
                        }
                        .tag(style.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .accessibilityHint("The progress icon traces the outline as files convert.")
                Picker("Clicking the icon", selection: $click) {
                    ForEach(ClickBehaviour.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup)
                Picker("When files are dropped on the icon", selection: $dropAction) {
                    Text("Ask: show them in the panel").tag("ask")
                    Divider()
                    ForEach(SettingsCatalog.panelItems) { item in
                        Text(item.id.hasPrefix("tool.") ? item.title : "Convert to \(item.title)").tag(item.id)
                    }
                }
                .accessibilityHint("Choose a format or tool to start at once when you drop files on the menu bar icon.")
                Toggle("Show Ameya in the Dock", isOn: $showInDock)
                    .accessibilityHint("Ameya always has its icon in the menu bar. This adds one to the Dock too.")
                    .onChange(of: showInDock) { _, _ in DockIcon.apply() }
            }

            Section("Favourites") {
                OrderedItemsEditor(noun: "favourite", all: SettingsCatalog.panelItems, chosen: $favourites,
                                   emptyText: "Pin the formats and tools you use most. They come first in the panel when they suit your files.")
                    .onChange(of: favourites) { _, new in PanelPreferences.favourites = new }
            }

            Section("Panel") {
                ForEach(PanelSection.allCases) { section in
                    SectionToggle(section: section)
                }
                Picker("Spacing", selection: $density) {
                    ForEach(PanelDensity.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Toggle("Larger text in the panel", isOn: $largerText)
                    .accessibilityHint("Makes the panel bigger, with larger text and buttons.")
                Toggle("Offer one-click “Convert to JPEG” for iPhone photos", isOn: $quickConvert)
                    .accessibilityHint("When every file waiting is a HEIC photo, a JPEG button comes first.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct SectionToggle: View {
    let section: PanelSection
    @AppStorage private var shown: Bool

    init(section: PanelSection) {
        self.section = section
        _shown = AppStorage(wrappedValue: true, PanelPreferences.sectionKey(section))
    }

    var body: some View {
        Toggle("Show “\(section.title)”", isOn: $shown)
    }
}

/// Settings → Keyboard & Mouse: the drag wheel and global shortcuts.
struct KeyboardMouseSettings: View {
    @StateObject private var shortcuts = ShortcutsModel()

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    ShortcutRecorder(action: action, model: shortcuts)
                }
            } header: {
                Text("Shortcuts that work in any app")
            } footer: {
                Text("Click a shortcut, then press the keys you want, with Control, Option or Command. Escape cancels; Delete clears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            WheelSettingsSection()
        }
        .formStyle(.grouped)
    }
}
