import AmeyaCore
import AppKit
import SwiftUI

/// `--snapshots`, continued: the menu bar icon in every state, the panel with favourites and
/// larger text, and the Settings tabs. Preferences changed for a picture are put back after.
extension Snapshots {
    static func renderMenuBarExtras(store: JobStore, results: ResultsModel, in folder: URL) async -> Bool {
        var ok = true
        ok = await render(IconSheet(), "menubar-icon", size: CGSize(width: 560, height: 300), in: folder) && ok
        ok = await render(IconSheet(), "menubar-icon-dark", size: CGSize(width: 560, height: 300), dark: true, in: folder) && ok

        let saved = [PanelPreferences.favouritesKey, PanelPreferences.largerTextKey].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        PanelPreferences.favourites = ["format.pdf", "format.jpeg", "tool.image.removeLocation", "format.png"]
        func panel() -> some View {
            MenuBarPanel().environmentObject(store).environmentObject(results).environmentObject(MenuBarModel())
        }
        ok = await render(panel(), "menubar-panel-favourites", size: MenuBarPanel.size, in: folder) && ok
        UserDefaults.standard.set(true, forKey: PanelPreferences.largerTextKey)
        ok = await render(panel(), "menubar-panel-larger-text", size: MenuBarPanel.currentSize, in: folder) && ok
        for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) }

        ok = await render(KeyboardMouseSettings(), "settings-keyboard-mouse", size: CGSize(width: 600, height: 1500), in: folder) && ok
        ok = await render(MenuSettings(), "settings-menu", size: CGSize(width: 600, height: 1100), in: folder) && ok
        return ok
    }
}

/// The menu bar icon's states, at menu bar size and enlarged, on a menu-bar-like strip.
private struct IconSheet: View {
    private let looks: [(String, StatusIcon.Look)] = [
        ("Idle", .idle), ("Working 35%", .working(0.35)), ("Working 80%", .working(0.8)),
        ("Done", .finished), ("Drop here", .dropTarget),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Ameya menu bar icon").font(.headline)
            HStack(spacing: 26) {
                ForEach(looks, id: \.0) { name, look in
                    VStack(spacing: 8) {
                        Image(nsImage: StatusIcon.image(look)).resizable().frame(width: 54, height: 54)
                        Image(nsImage: StatusIcon.image(look))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 26) {
                ForEach(StatusIcon.Style.allCases) { style in
                    HStack(spacing: 8) {
                        Image(nsImage: StatusIcon.image(.idle, style: style))
                        Text(style.title).font(.caption)
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
