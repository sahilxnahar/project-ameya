import AmeyaCore
import AppKit
import SwiftUI

/// Something that can be picked in an ordered list: a format, tool or wheel wedge.
struct PickableItem: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
}

/// The formats and tools Settings offers, worked out once for this Mac.
@MainActor
enum SettingsCatalog {
    static let writable = FileFormat.systemWritable()
    static let tools = ToolCatalog(writable: writable).tools

    static var formats: [FileFormat] {
        FileFormat.allCases.filter { writable.contains($0) }.sorted(by: FormatRank.isMoreLikely)
    }

    /// Formats and tools, as favourites and drop actions use them ("format.jpeg", "tool.…").
    static var panelItems: [PickableItem] {
        formats.map { PickableItem(id: "format.\($0.rawValue)", title: $0.displayName, systemImage: Theme.symbol(for: $0)) }
            + tools.map { PickableItem(id: "tool.\($0.id)", title: $0.title, systemImage: $0.systemImage) }
    }

    /// What each wheel can show, with `WheelChoice` ids.
    static func wedges(_ ring: WheelRing) -> [PickableItem] {
        switch ring {
        case .convert:
            formats.map { PickableItem(id: "convert.\($0.rawValue)", title: $0.displayName, systemImage: WheelChoices.symbol(for: $0)) }
        case .tools:
            tools.map { PickableItem(id: "tool.\($0.id)", title: $0.title, systemImage: $0.systemImage) }
        case .actions:
            [PickableItem(id: "action.open", title: "Open in Ameya", systemImage: "macwindow"),
             PickableItem(id: "action.copyPath", title: "Copy path", systemImage: "doc.on.clipboard"),
             PickableItem(id: "action.showInFinder", title: "Show in Finder", systemImage: "folder")]
        }
    }
}

/// An ordered list the user builds: add from a menu, move up and down, remove. Every control is
/// a plain button, so it works with the keyboard (Tab, Space) and VoiceOver.
struct OrderedItemsEditor: View {
    /// "favourite", "wedge": used in VoiceOver labels.
    let noun: String
    let all: [PickableItem]
    @Binding var chosen: [String]
    let emptyText: String

    private var chosenItems: [PickableItem] { chosen.compactMap { id in all.first { $0.id == id } } }
    private var remaining: [PickableItem] { all.filter { !chosen.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if chosenItems.isEmpty {
                Text(emptyText).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(chosenItems.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 6) {
                    Image(systemName: item.systemImage)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(item.title)
                    Spacer()
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                        .help("Move up")
                        .accessibilityLabel("Move \(item.title) up")
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == chosenItems.count - 1)
                        .help("Move down")
                        .accessibilityLabel("Move \(item.title) down")
                    Button { remove(item) } label: { Image(systemName: "minus.circle") }
                        .help("Remove")
                        .accessibilityLabel("Remove \(item.title)")
                }
                .buttonStyle(.borderless)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(item.title), \(noun) \(index + 1) of \(chosenItems.count)")
            }
            HStack {
                Menu("Add \(noun.capitalized)…") {
                    ForEach(remaining) { item in
                        Button { chosen.append(item.id) } label: { Label(item.title, systemImage: item.systemImage) }
                    }
                }
                .fixedSize()
                .disabled(remaining.isEmpty)
                .accessibilityHint("Adds one to the end of the list.")
                if !chosen.isEmpty {
                    Button("Clear") { chosen = [] }
                        .accessibilityLabel("Clear all \(noun)s")
                }
            }
        }
    }

    private func move(_ index: Int, by step: Int) {
        let ids = chosenItems.map(\.id)
        let target = index + step
        guard ids.indices.contains(index), ids.indices.contains(target) else { return }
        var reordered = ids
        reordered.swapAt(index, target)
        chosen = reordered
        Feedback.announce("Moved \(chosenItems[target].title) to position \(target + 1).")
    }

    private func remove(_ item: PickableItem) {
        chosen.removeAll { $0 == item.id }
        Feedback.announce("Removed \(item.title).")
    }
}

/// Keeps every shortcut and its warnings in one place, so recorders can see each other.
@MainActor
final class ShortcutsModel: ObservableObject {
    @Published private(set) var shortcuts: [HotKeyAction: HotKeyShortcut] = [:]
    @Published private(set) var problems: [HotKeyAction: String] = [:]
    @Published var recording: HotKeyAction?

    init() { reload() }

    func reload() {
        shortcuts = Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.compactMap { action in
            HotKeySettings.shortcut(for: action).map { (action, $0) }
        })
        problems = GlobalHotKey.shared.applySettings()
    }

    /// Sets a shortcut. One already used by another Ameya action moves here.
    func set(_ shortcut: HotKeyShortcut?, for action: HotKeyAction) {
        if let shortcut, let other = shortcuts.first(where: { $0.value == shortcut && $0.key != action })?.key {
            HotKeySettings.set(nil, for: other)
            Feedback.announce("\(shortcut.spoken) moved from “\(other.title)”.")
        }
        HotKeySettings.set(shortcut, for: action)
        reload()
        if let shortcut, problems[action] == nil { Feedback.announce("Shortcut set to \(shortcut.spoken).") }
    }

    func reset(_ action: HotKeyAction) {
        HotKeySettings.reset(action)
        reload()
    }
}

/// Click, press the keys, done. Escape cancels; Delete clears.
struct ShortcutRecorder: View {
    let action: HotKeyAction
    @ObservedObject var model: ShortcutsModel
    @State private var monitor: Any?
    @State private var note: String?

    private var shortcut: HotKeyShortcut? { model.shortcuts[action] }
    private var isRecording: Bool { model.recording == action }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                HStack(spacing: 6) {
                    Button(action: toggleRecording) {
                        Text(isRecording ? "Press keys…" : shortcut?.symbols ?? "Record Shortcut")
                            .font(shortcut == nil || isRecording ? .body : .body.monospaced())
                            .frame(minWidth: 110)
                    }
                    .accessibilityLabel(isRecording ? "Recording. Press the new shortcut, or Escape to cancel."
                                                    : "\(action.title): \(shortcut?.spoken ?? "no shortcut")")
                    .accessibilityHint(isRecording ? "" : "Press to record a new shortcut.")
                    if shortcut != nil {
                        Button { model.set(nil, for: action) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Clear this shortcut")
                            .accessibilityLabel("Clear the shortcut for \(action.title)")
                    }
                    if shortcut != action.standard {
                        Button("Default") { model.reset(action) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Restore the default shortcut for \(action.title)")
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                    Text(action.help).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stop)
    }

    private var warnings: [String] {
        var list: [String] = []
        if let note { list.append(note) }
        if let problem = model.problems[action] { list.append(problem) }
        if let shortcut, let meaning = SystemShortcuts.meaning(of: shortcut) {
            list.append("macOS uses \(shortcut.symbols) for “\(meaning)”. If that's turned on in System Settings › Keyboard › Keyboard Shortcuts, it wins.")
        }
        return list
    }

    private func toggleRecording() {
        isRecording ? stop() : start()
    }

    private func start() {
        note = nil
        model.recording = action
        Feedback.announce("Press the new shortcut, with Control, Option or Command. Escape cancels, Delete clears.")
        GlobalHotKey.shared.handlersPaused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                if event.keyCode == 53 { // Escape
                    stop()
                } else if plain && (event.keyCode == 51 || event.keyCode == 117) { // Delete, Forward Delete
                    model.set(nil, for: action)
                    stop()
                } else if let new = HotKeyShortcut(event: event) {
                    model.set(new, for: action)
                    stop()
                } else {
                    note = "Include Control, Option or Command, so the shortcut doesn't get in the way of typing."
                    Feedback.announce(note ?? "")
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard model.recording == action else { return }
        model.recording = nil
        GlobalHotKey.shared.handlersPaused = false
        model.reload() // Registers again and reports any clash.
    }
}
