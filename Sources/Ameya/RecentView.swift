import AmeyaCore
import AppKit
import SwiftUI

/// Files Ameya made before, kept across launches (paths and sizes only).
struct RecentSection: View {
    @EnvironmentObject private var results: ResultsModel
    @Binding var preview: URL?
    @AppStorage("recentExpanded") private var expanded = true
    @State private var problem: String?

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(results.recent.items.prefix(8)) { file in
                    RecentRow(file: file, preview: $preview, problem: $problem)
                }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Clear List") { results.clearRecent() }
                        .buttonStyle(.borderless)
                        .accessibilityHint("Forgets this list. Your files stay where they are.")
                        .accessibilityIdentifier("clear-recent")
                }
            }
            .padding(.top, 6)
        } label: {
            SectionTitle(text: "Recent", systemImage: "clock.arrow.circlepath")
        }
        .accessibilityIdentifier("recent")
    }
}

private struct RecentRow: View {
    let file: RecentFile
    @Binding var preview: URL?
    @Binding var problem: String?
    @EnvironmentObject private var results: ResultsModel
    @FocusState private var focused: Bool

    var body: some View {
        let exists = results.exists(file)
        HStack(spacing: 8) {
            Image(systemName: file.isFolder ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                Text(exists ? caption : "Moved or deleted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if exists {
                Button("Open") { NSWorkspace.shared.open(file.url) }
                    .accessibilityHint("Opens \(file.name).")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
                    .accessibilityLabel("Show in Finder")
                Button {
                    problem = results.undo(file)
                } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Undo: move to the Trash")
                    .accessibilityLabel("Undo")
                    .accessibilityHint("Moves this file to the Trash. Your original is not touched.")
                    .disabled(!results.canUndo(file))
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(focused ? Theme.accent.opacity(0.12) : .clear))
        .focusable(exists)
        .focused($focused)
        .onKeyPress(.space) {
            guard exists else { return .ignored }
            preview = file.url
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(exists ? "\(file.name), \(file.sizeChange.description)" : "\(file.name), moved or deleted")
        .accessibilityIdentifier("recent-row")
    }

    private var caption: String {
        file.isFolder ? "Folder" : "\(file.sizeChange.sizes) · \(file.sizeChange.description)"
    }
}
