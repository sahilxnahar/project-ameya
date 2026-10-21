import AmeyaCore
import AppKit
import SwiftUI

/// Settings › Watch folders: the list of watched folders and what each does with new files.
struct WatchFoldersSection: View {
    var body: some View {
        if let delegate = AppDelegate.shared {
            WatchFoldersList(watch: delegate.watchFolders, recipes: delegate.recipes, store: delegate.store)
        } else {
            Section("Watch folders") {
                Text("New files in folders you choose can be converted automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct WatchFoldersList: View {
    @ObservedObject var watch: WatchFolders
    @ObservedObject var recipes: RecipeLibrary
    let store: JobStore
    @State private var editing: WatchRule?

    var body: some View {
        Section {
            Toggle("Pause all watch folders", isOn: Binding(get: { watch.isPaused }, set: { watch.setPaused($0) }))
                .accessibilityHint("Stops watching every folder until you turn this off. Also in the menu bar.")
            ForEach(watch.rules) { rule in
                HStack {
                    Toggle(isOn: Binding(get: { rule.isEnabled }, set: { on in
                        var changed = rule
                        changed.isEnabled = on
                        watch.update(changed)
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.folder.name)
                            Text(summary(rule)).font(.caption).foregroundStyle(.secondary)
                            if let problem = watch.problems[rule.id] {
                                Label(problem, systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    .accessibilityLabel("Watch \(rule.folder.name): \(summary(rule))")
                    Spacer()
                    Button("Edit…") { editing = rule }
                        .accessibilityLabel("Edit \(rule.folder.name)")
                    Button(role: .destructive) { watch.remove(rule.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Stop watching this folder")
                        .accessibilityLabel("Remove \(rule.folder.name)")
                }
            }
            Button("Add Folder…", action: addFolder)
                .accessibilityHint("Pick a folder; new files that arrive in it will be converted")
            Text("Only files that arrive while Ameya is open are converted. Originals stay where they are unless you choose otherwise.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Watch folders")
        }
        .sheet(item: $editing) { rule in
            WatchRuleEditor(rule: rule, recipes: recipes, store: store) { saved in
                if let saved { watch.update(saved) }
                editing = nil
            }
        }
    }

    private func summary(_ rule: WatchRule) -> String {
        let kinds = RecipePlanner.list(rule.fileTypes)
        let action: String = switch rule.action {
        case let .convert(target): "\(kinds) → \(target.displayName)"
        case let .recipe(id): "\(kinds) → \(recipes.recipe(id: id)?.name ?? "missing recipe")"
        }
        let place = rule.output == .nextToOriginals ? "saved beside them" : "saved to the Ameya folder"
        return "\(action), \(place)" + (rule.original == .trash ? ", originals to the Trash" : "")
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Watch"
        panel.message = "Choose a folder. New files that arrive in it will be converted."
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(options: [.withSecurityScope]) else { return }
        editing = WatchRule(isEnabled: true, folder: .picked(bookmark: bookmark, name: url.lastPathComponent),
                            fileTypes: [.heic], action: .convert(.jpeg))
    }
}

/// The sheet for one watched folder: which files, what to do, where the result goes.
struct WatchRuleEditor: View {
    @State private var rule: WatchRule
    @ObservedObject var recipes: RecipeLibrary
    let store: JobStore
    let finish: (WatchRule?) -> Void

    init(rule: WatchRule, recipes: RecipeLibrary, store: JobStore, finish: @escaping (WatchRule?) -> Void) {
        _rule = State(initialValue: rule)
        self.recipes = recipes
        self.store = store
        self.finish = finish
    }

    private var usableRecipes: [Recipe] { recipes.recipes.filter { recipes.analysis(of: $0).isValid } }

    /// Every format this Mac can make from something.
    private var targets: [FileFormat] { recipes.planner.reachableTargets }

    /// File types that fit the chosen action.
    private var fitting: [FileFormat] {
        switch rule.action {
        case let .convert(target): recipes.planner.sources(convertingTo: target)
        case let .recipe(id): recipes.recipe(id: id).map { recipes.analysis(of: $0).accepts } ?? []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Folder: \(rule.folder.name)") {
                    Picker("When a file arrives", selection: actionKind) {
                        Text("Convert it to a format").tag(0)
                        Text("Run a recipe").tag(1)
                    }
                    switch rule.action {
                    case let .convert(target):
                        Picker("Format", selection: Binding(get: { target }, set: { setAction(.convert($0)) })) {
                            ForEach(targets) { Text($0.displayName).tag($0) }
                        }
                    case let .recipe(id):
                        Picker("Recipe", selection: Binding(get: { id }, set: { setAction(.recipe($0)) })) {
                            ForEach(usableRecipes) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                Section("Only these kinds of files") {
                    FormatTypePicker(available: fitting, selection: Binding(
                        get: { Set(rule.fileTypes) },
                        set: { chosen in rule.fileTypes = FileFormat.allCases.filter(chosen.contains) }))
                }
                Section("Afterwards") {
                    Picker("Save the result", selection: $rule.output) {
                        Text("Next to the original").tag(WatchRule.Output.nextToOriginals)
                        Text("In the Ameya folder (Settings › Save converted files to)").tag(WatchRule.Output.ameyaFolder)
                    }
                    Picker("The original file", selection: $rule.original) {
                        Text("Stays where it is").tag(WatchRule.Original.keep)
                        Text("Moves to the Trash (you can put it back)").tag(WatchRule.Original.trash)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button("Save") { finish(rule) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.fileTypes.isEmpty)
            }
            .padding()
        }
        .frame(width: 460, height: 560)
        .tint(Theme.accent)
    }

    private var actionKind: Binding<Int> {
        Binding(get: { if case .recipe = rule.action { 1 } else { 0 } }, set: { kind in
            if kind == 1, let first = usableRecipes.first { setAction(.recipe(first.id)) }
            if kind == 0 { setAction(.convert(.jpeg)) }
        })
    }

    /// Changing what happens keeps only the file types that still fit.
    private func setAction(_ action: WatchRule.Action) {
        rule.action = action
        let fits = Set(fitting)
        rule.fileTypes = rule.fileTypes.filter(fits.contains)
    }
}

/// Toggles for file types, grouped by kind ("Pictures", "Videos", …).
struct FormatTypePicker: View {
    let available: [FileFormat]
    @Binding var selection: Set<FileFormat>

    private static func name(_ family: FileFormat.Family) -> String {
        switch family {
        case .image: "Pictures"
        case .document: "Documents"
        case .audio: "Sound"
        case .video: "Videos"
        case .subtitle: "Subtitles"
        case .archive: "Archives"
        case .data: "Data"
        case .contacts: "Contacts"
        case .geo: "Maps and tracks"
        case .model: "3D models"
        case .compressed: "Compressed files"
        }
    }

    var body: some View {
        if available.isEmpty {
            Text("No kind of file fits this choice.").foregroundStyle(.secondary)
        }
        let families = available.reduce(into: [FileFormat.Family]()) { if !$0.contains($1.family) { $0.append($1.family) } }
        ForEach(families, id: \.self) { family in
            let formats = available.filter { $0.family == family }
            let chosen = formats.filter(selection.contains).count
            DisclosureGroup("\(Self.name(family)) (\(chosen) of \(formats.count))") {
                ForEach(formats) { format in
                    Toggle(format.displayName, isOn: Binding(
                        get: { selection.contains(format) },
                        set: { on in if on { selection.insert(format) } else { selection.remove(format) } }))
                }
            }
            .accessibilityLabel("\(Self.name(family)), \(chosen) of \(formats.count) chosen")
        }
    }
}
