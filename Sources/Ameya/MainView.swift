import AmeyaCore
import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The main window: drop files → pick what you want → results. One obvious step at a time.
struct MainView: View {
    @EnvironmentObject private var store: JobStore
    @EnvironmentObject private var results: ResultsModel
    @AppStorage(Preferences.hasSeenOnboardingKey) private var hasSeenOnboarding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isTargeted = false
    @State private var isImporting = false
    @State private var panelTool: Tool?
    @State private var preview: URL?

    private var isEmpty: Bool { store.pending.isEmpty && store.jobs.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if store.pending.isEmpty {
                        if isEmpty {
                            EmptyDropArea(isTargeted: isTargeted) { isImporting = true }
                        } else {
                            compactDropHint
                        }
                    } else {
                        pendingFiles
                        choices
                    }
                    if !store.unsupported.isEmpty { unsupportedNote }
                    if !store.jobs.isEmpty { ResultsSection(preview: $preview) }
                    if !results.recent.items.isEmpty { RecentSection(preview: $preview) }
                }
                .padding(20)
                .animation(Theme.arrival(reduceMotion: reduceMotion), value: store.pending.map(\.id))
            }
            footer
        }
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 820, minHeight: 500, idealHeight: 620)
        .tint(Theme.accent)
        .overlay { if isTargeted && !isEmpty { dropOverlay } }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return !urls.isEmpty
        } isTargeted: { isTargeted = $0 }
        .onPasteCommand(of: [.fileURL, .png, .tiff, .jpeg, .pdf]) { _ in pasteFromClipboard() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
        .sheet(item: $panelTool) { tool in
            ToolPanelSheet(tool: tool, formats: store.pending.map(\.format)) { options in
                panelTool = nil
                if let options { store.run(tool, options: options) }
            }
        }
        .sheet(isPresented: Binding(get: { !hasSeenOnboarding }, set: { if !$0 { hasSeenOnboarding = true } })) {
            OnboardingView { hasSeenOnboarding = true }
        }
        .quickLookPreview($preview)
        .background {
            // ⌘O works wherever focus is, even when the big button isn't on screen.
            Button("Choose Files…") { isImporting = true }
                .keyboardShortcut("o")
                .hidden()
                .accessibilityHidden(true)
        }
    }

    // MARK: Pieces

    private var compactDropHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .foregroundStyle(Theme.accent)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text("Drop more files anywhere in this window, or")
                .foregroundStyle(.secondary)
            Button("Choose Files…") { isImporting = true }
                .accessibilityHint("Shortcut: Command O.")
                .accessibilityIdentifier("choose-files")
            Spacer(minLength: 0)
        }
        .padding(12)
        .card()
    }

    private var pendingFiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: store.pending.count == 1 ? "1 file ready" : "\(store.pending.count) files ready")
                Spacer()
                Button("Add More…") { isImporting = true }
                    .buttonStyle(.borderless)
                    .accessibilityHint("Pick more files. Shortcut: Command O.")
                    .accessibilityIdentifier("add-more")
                Button("Clear") { store.clearPending() }
                    .buttonStyle(.borderless)
                    .accessibilityHint("Empties this list. Your files aren't touched.")
                    .accessibilityIdentifier("clear-pending")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], spacing: 8) {
                ForEach(store.pending) { file in
                    PendingFileCard(file: file) { store.remove(file) }
                        .transition(Theme.cardTransition(reduceMotion: reduceMotion))
                }
            }
        }
    }

    @ViewBuilder private var choices: some View {
        let targets = FormatChoices(targets: store.targets, sources: store.pending.map(\.format))
        let tools = store.tools
        if targets.isEmpty && tools.isEmpty {
            Label("These files have nothing in common to convert to. Try them one kind at a time.",
                  systemImage: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
        }
        if !targets.isEmpty {
            ConvertToSection(choices: targets, notes: store.possibleLosses(to:)) { store.convert(to: $0) }
        }
        if !tools.isEmpty {
            ToolsSection(tools: tools) { tool in
                if tool.panel != nil { panelTool = tool } else { store.run(tool) }
            }
        }
    }

    private var unsupportedNote: some View {
        Label("Ameya can't convert \(store.unsupported.joined(separator: ", ")) yet.",
              systemImage: "questionmark.folder")
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("unsupported")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                try? FileManager.default.createDirectory(at: store.outputDirectory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(store.outputDirectory)
            } label: {
                Label("Saving to \(Self.friendlyPath(store.outputDirectory))", systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.borderless)
            .help("Open the folder in Finder")
            .accessibilityHint("Opens the folder where converted files are saved. Change it in Settings.")
            .accessibilityIdentifier("output-folder")
            Spacer(minLength: 8)
            Label("Stays on this Mac", systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Ameya never uploads anything. Every conversion runs on this Mac.")
                .accessibilityLabel("Everything stays on this Mac. Nothing is uploaded.")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.bar))
        .overlay(alignment: .top) { Divider() }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.accent.opacity(reduceTransparency ? 0.25 : 0.08)))
            .overlay {
                Label("Let go to add", systemImage: "plus.circle.fill")
                    .font(.title2.weight(.semibold))
                    .padding(14)
                    .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
            }
            .padding(8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// "Downloads › Ameya" rather than "/Users/name/Downloads/Ameya".
    static func friendlyPath(_ url: URL) -> String {
        let home = JobStore.realDownloadsDirectory().deletingLastPathComponent().standardizedFileURL.pathComponents
        var parts = url.standardizedFileURL.pathComponents
        if parts.starts(with: home) { parts.removeFirst(home.count) } else { parts = Array(parts.suffix(2)) }
        return parts.isEmpty ? url.lastPathComponent : parts.joined(separator: " › ")
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

    private func pasteFromClipboard() {
        switch ClipboardActions.read() {
        case .files(let urls)?: add(urls)
        case .image(let url, _)?: add([url])
        case nil: Feedback.announce("There's no file or picture on the clipboard.")
        }
    }
}
