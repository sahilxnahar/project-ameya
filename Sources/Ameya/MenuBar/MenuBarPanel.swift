import AmeyaCore
import AppKit
import QuickLook
import SwiftUI

/// What the panel asks its owner (`StatusItemController`) to do: things that need AppKit.
@MainActor
final class MenuBarModel: ObservableObject {
    @Published var isDropTargeted = false
    var close: () -> Void = {}
    var openWindow: () -> Void = {}
    var openSettings: () -> Void = {}
    var chooseFiles: () -> Void = {}
}

/// UserDefaults key: offer "Convert to JPEG" first when every waiting file is an iPhone photo.
enum QuickConvert {
    static let key = "quickConvertHEIC"
    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// The menu bar panel: a compact main window. It reuses the window's pieces (drop area, file
/// cards, "Convert to", tools, results with Undo, Recent) over the same `JobStore`, so files
/// added here are waiting in the big window too, and the other way round.
struct MenuBarPanel: View {
    @EnvironmentObject private var store: JobStore
    @EnvironmentObject private var results: ResultsModel
    @EnvironmentObject private var model: MenuBarModel
    @AppStorage(QuickConvert.key) private var quickConvert = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var panelTool: Tool?
    @State private var preview: URL?

    static let size = CGSize(width: 380, height: 560)
    private static let maxTools = 4
    private static let maxCards = 4

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let tool = panelTool {
                        ToolPanelSheet(tool: tool, formats: store.pending.map(\.format)) { options in
                            panelTool = nil
                            if let options { store.run(tool, options: options) }
                        }
                        .padding(-6)
                    } else {
                        content
                    }
                }
                .padding(14)
                .animation(Theme.arrival(reduceMotion: reduceMotion), value: store.pending.map(\.id))
            }
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .tint(Theme.accent)
        .overlay { if model.isDropTargeted { dropOverlay } }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return !urls.isEmpty
        } isTargeted: { model.isDropTargeted = $0 }
        .onPasteCommand(of: [.fileURL, .png, .tiff, .jpeg, .pdf]) { _ in paste() }
        .quickLookPreview($preview)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ameya")
        .accessibilityIdentifier("menu-bar-panel")
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: StatusIcon.image(.finished))
                .renderingMode(.template)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("Ameya").font(.headline)
            Spacer()
            Label("Stays on this Mac", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Ameya never uploads anything. Every conversion runs on this Mac.")
                .accessibilityLabel("Everything stays on this Mac. Nothing is uploaded.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if store.pending.isEmpty {
            if store.jobs.isEmpty {
                EmptyDropArea(isTargeted: model.isDropTargeted, choose: model.chooseFiles)
            } else {
                dropHint
            }
        } else {
            pendingFiles
            choices
        }
        if !store.unsupported.isEmpty {
            Label("Ameya can't convert \(store.unsupported.joined(separator: ", ")) yet.", systemImage: "questionmark.folder")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if !store.jobs.isEmpty { ResultsSection(preview: $preview) }
        if !results.olderRecent(than: store.jobs).isEmpty { RecentSection(preview: $preview) }
    }

    private var dropHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("Drop more files here, or")
                .foregroundStyle(.secondary)
            Button("Choose Files…", action: model.chooseFiles)
                .accessibilityIdentifier("panel-choose-files")
            Spacer(minLength: 0)
        }
        .padding(10)
        .card()
    }

    private var pendingFiles: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(text: store.pending.count == 1 ? "1 file ready" : "\(store.pending.count) files ready")
                Spacer()
                Button("Add…", action: model.chooseFiles)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Add more files")
                Button("Clear") { store.clearPending() }
                    .buttonStyle(.borderless)
                    .accessibilityHint("Empties this list. Your files aren't touched.")
            }
            ForEach(store.pending.prefix(Self.maxCards)) { file in
                PendingFileCard(file: file) { store.remove(file) }
                    .transition(Theme.cardTransition(reduceMotion: reduceMotion))
            }
            if store.pending.count > Self.maxCards {
                Text("and \(store.pending.count - Self.maxCards) more")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "Convert to JPEG" first, when every file is an iPhone photo and Settings allows it.
    private var quickTarget: FileFormat? {
        guard quickConvert, !store.pending.isEmpty, store.pending.allSatisfy({ $0.format == .heic }),
              store.targets.contains(.jpeg) else { return nil }
        return .jpeg
    }

    @ViewBuilder private var choices: some View {
        let targets = FormatChoices(targets: store.targets, sources: store.pending.map(\.format))
        let tools = store.tools
        if let quick = quickTarget {
            Button {
                store.convert(to: quick)
            } label: {
                Label("Convert to \(quick.displayName)", systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Saves a JPEG copy of each photo. Your originals aren't changed.")
            .accessibilityIdentifier("quick-convert")
        }
        if targets.isEmpty && tools.isEmpty {
            Label("These files have nothing in common to convert to. Try them one kind at a time.",
                  systemImage: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
        }
        if !targets.isEmpty {
            ConvertToSection(choices: targets, notes: store.possibleLosses(to:)) { store.convert(to: $0) }
        }
        if !tools.isEmpty {
            ToolsSection(tools: Array(tools.prefix(Self.maxTools))) { tool in
                if tool.panel != nil { panelTool = tool } else { store.run(tool) }
            }
            if tools.count > Self.maxTools {
                Button("All \(tools.count) tools in the Ameya window…", action: model.openWindow)
                    .buttonStyle(.borderless)
                    .accessibilityHint("Opens the big window with these files ready.")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button(action: model.openWindow) {
                Label("Open Window", systemImage: "macwindow")
            }
            .keyboardShortcut("n")
            .help("Open the big Ameya window (⌘N)")
            .accessibilityHint("Shortcut: Command N.")
            .accessibilityIdentifier("panel-open-window")
            Button(action: paste) {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .help("Add the clipboard's files or picture")
            .accessibilityLabel("Paste from clipboard")
            .accessibilityHint("Adds the files or picture on the clipboard.")
            Spacer()
            Button(action: model.openSettings) {
                Image(systemName: "gearshape")
            }
            .keyboardShortcut(",")
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
            .accessibilityHint("Shortcut: Command comma.")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .keyboardShortcut("q")
            .help("Quit Ameya (⌘Q)")
            .accessibilityLabel("Quit Ameya")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.bar))
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.accent.opacity(reduceTransparency ? 0.25 : 0.08)))
            .padding(6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Actions

    private func add(_ urls: [URL]) {
        let before = store.pending.count
        store.add(urls)
        let added = store.pending.count - before
        guard added > 0 else { return }
        Feedback.play(.added)
        Feedback.announce(added == 1 ? "Added 1 file. Pick what you want it to become."
                                     : "Added \(added) files. Pick what you want them to become.")
    }

    private func paste() {
        switch ClipboardActions.read() {
        case .files(let urls)?: add(urls)
        case .image(let url, _)?: add([url])
        case nil: Feedback.announce("There's no file or picture on the clipboard.")
        }
    }
}
