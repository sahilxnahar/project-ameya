import AmeyaCore
import Foundation

/// Settings → Menu: how the menu bar icon and its panel behave. All in UserDefaults, all
/// optional: an unset key means the default.
enum PanelPreferences {
    static let favouritesKey = "panel.favourites"
    static let densityKey = "panel.density"
    static let largerTextKey = "panel.largerText"
    static let clickKey = "menubar.click"
    static let iconStyleKey = "menubar.iconStyle"
    static let dropActionKey = "menubar.dropAction"
    static let lastTargetKey = "menubar.lastTarget"
    static func sectionKey(_ section: PanelSection) -> String { "panel.show.\(section.rawValue)" }

    /// Pinned formats and tools, shown first in the panel ("format.jpeg", "tool.image.rotate").
    static var favourites: [String] {
        get { UserDefaults.standard.stringArray(forKey: favouritesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: favouritesKey) }
    }

    static func isShown(_ section: PanelSection) -> Bool {
        UserDefaults.standard.object(forKey: sectionKey(section)) as? Bool ?? true
    }

    static var largerText: Bool { UserDefaults.standard.bool(forKey: largerTextKey) }

    static var density: PanelDensity {
        UserDefaults.standard.string(forKey: densityKey).flatMap(PanelDensity.init(rawValue:)) ?? .comfortable
    }

    static var click: ClickBehaviour {
        UserDefaults.standard.string(forKey: clickKey).flatMap(ClickBehaviour.init(rawValue:)) ?? .leftOpensPanel
    }

    static var iconStyle: StatusIcon.Style {
        UserDefaults.standard.string(forKey: iconStyleKey).flatMap(StatusIcon.Style.init(rawValue:)) ?? .progress
    }

    /// What dropping files on the menu bar icon does: nil asks (opens the panel), otherwise a
    /// favourite-style id that runs at once.
    static var dropAction: String? {
        let value = UserDefaults.standard.string(forKey: dropActionKey)
        return value == nil || value == "ask" ? nil : value
    }

    /// The format of the last plain conversion, for the "convert again" shortcut.
    static var lastTarget: FileFormat? {
        get { UserDefaults.standard.string(forKey: lastTargetKey).flatMap(FileFormat.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: lastTargetKey) }
    }
}

enum PanelSection: String, CaseIterable, Identifiable {
    case favourites, convert, tools, results, recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favourites: "Favourites"
        case .convert: "Convert to"
        case .tools: "Tools"
        case .results: "Results"
        case .recent: "Recent"
        }
    }
}

enum PanelDensity: String, CaseIterable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
    var title: String { self == .compact ? "Compact" : "Comfortable" }
}

enum ClickBehaviour: String, CaseIterable, Identifiable {
    /// Click: the panel. Right-click or Control-click: the menu.
    case leftOpensPanel
    /// Click: the menu. Right-click or Control-click: the panel.
    case leftOpensMenu
    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftOpensPanel: "Click opens the panel, right-click the menu"
        case .leftOpensMenu: "Click opens the menu, right-click the panel"
        }
    }
}

/// A format or tool the user can pin, or choose as the drop action: "format.jpeg", "tool.<id>".
struct PanelItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case format(FileFormat)
        case tool(String)

        var isTool: Bool { if case .tool = self { true } else { false } }
    }

    let kind: Kind
    let title: String
    let systemImage: String

    var id: String {
        switch kind {
        case let .format(format): "format.\(format.rawValue)"
        case let .tool(id): "tool.\(id)"
        }
    }

    /// Formats this Mac can write, worked out once (it asks ImageIO and looks for FFmpeg).
    private static let writable = FileFormat.systemWritable()

    /// Every pinnable item, formats first (most likely first), then tools in catalog order.
    @MainActor
    static func all(store: JobStore) -> [PanelItem] {
        let formats = FileFormat.allCases.filter { writable.contains($0) }.sorted(by: FormatRank.isMoreLikely)
        return formats.map { PanelItem(kind: .format($0), title: $0.displayName, systemImage: Theme.symbol(for: $0)) }
            + store.catalog.tools.map { PanelItem(kind: .tool($0.id), title: $0.title, systemImage: $0.systemImage) }
    }

    @MainActor
    static func find(_ id: String, store: JobStore) -> PanelItem? {
        if id.hasPrefix("format."), let format = FileFormat(rawValue: String(id.dropFirst(7))) {
            return PanelItem(kind: .format(format), title: format.displayName, systemImage: Theme.symbol(for: format))
        }
        if id.hasPrefix("tool."), let tool = store.catalog.tools.first(where: { $0.id == String(id.dropFirst(5)) }) {
            return PanelItem(kind: .tool(tool.id), title: tool.title, systemImage: tool.systemImage)
        }
        return nil
    }
}
