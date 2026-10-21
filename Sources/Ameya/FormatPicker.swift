import AmeyaCore
import SwiftUI

/// "Convert to": likely choices grouped by what people want, a search field, and "More formats".
struct ConvertToSection: View {
    let choices: FormatChoices
    let notes: (FileFormat) -> [ConversionNote]
    let convert: (FileFormat) -> Void
    @State private var query = ""
    @State private var showMore = false
    @FocusState private var searchFocused: Bool

    private var matches: [FileFormat] {
        FormatSearch.filter(choices.all, query: query).sorted(by: FormatRank.isMoreLikely)
    }

    /// The single most likely choice: Return converts to it.
    private var suggested: FileFormat? { choices.main.first?.formats.first }

    private let columns = [GridItem(.adaptive(minimum: 112), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(text: "Convert to")
                Spacer()
                searchField
            }
            if query.isEmpty {
                ForEach(choices.main) { group in groupView(group) }
                if !choices.more.isEmpty {
                    DisclosureGroup(isExpanded: $showMore) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(choices.more) { group in groupView(group) }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("More formats (\(choices.more.flatMap(\.formats).count))")
                            .font(.callout.weight(.medium))
                    }
                    .accessibilityIdentifier("more-formats")
                    .accessibilityHint("Shows less common formats.")
                }
            } else if matches.isEmpty {
                Text("No format matches “\(query)”. Try a name like JPEG, Word or MP3.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("search-no-results")
            } else {
                grid(matches)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Type to find a format", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 170)
                .focused($searchFocused)
                .onSubmit { if let first = matches.first, !query.isEmpty { convert(first) } }
                .onExitCommand { query = "" }
                .accessibilityLabel("Find a format")
                .accessibilityHint("Type a name like JPEG or Word, then press Return to convert to the first match. Escape clears.")
                .accessibilityIdentifier("format-search")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .card(highlighted: searchFocused)
    }

    private func groupView(_ group: FormatGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(group.kind.title, systemImage: group.kind.systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .accessibilityAddTraits(.isHeader)
            grid(group.formats)
        }
    }

    private func grid(_ formats: [FileFormat]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(formats) { format in
                TargetChip(target: format, notes: notes(format), isSuggested: format == suggested && query.isEmpty) {
                    convert(format)
                }
            }
        }
    }
}

private struct TargetChip: View {
    let target: FileFormat
    let notes: [ConversionNote]
    let isSuggested: Bool
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            HStack(spacing: 4) {
                Text(target.displayName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if !notes.isEmpty {
                    // A shape, not a colour, says "read the note first".
                    Image(systemName: "info.circle").font(.caption).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 26)
        }
        .controlSize(.large)
        .help(notes.isEmpty ? "Convert to \(target.displayName)" : notes.map(\.message).joined(separator: "\n"))
        .accessibilityLabel("Convert to \(target.displayName)")
        .accessibilityHint(([isSuggested ? "Suggested. Press Return." : nil] + notes.map(\.message)).compactMap { $0 }.joined(separator: " "))
        .accessibilityIdentifier("target-\(target.rawValue)")

        if isSuggested {
            button.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

/// Things to do besides changing the format, each with a clear icon.
struct ToolsSection: View {
    let tools: [Tool]
    let run: (Tool) -> Void
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Or use a tool")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(tools) { tool in
                    Button { run(tool) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tool.systemImage)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 20)
                            Text(tool.title).lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            if tool.panel != nil {
                                Image(systemName: "ellipsis").foregroundStyle(.secondary).accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help(tool.help)
                    .accessibilityLabel(tool.panel == nil ? tool.title : "\(tool.title)…")
                    .accessibilityHint(tool.help + (tool.panel == nil ? "" : " Asks a question first."))
                    .accessibilityIdentifier("tool-\(tool.id)")
                }
            }
        }
    }
}

/// Hosts a tool's settings panel with a Cancel button (Escape) around it.
struct ToolPanelSheet: View {
    let tool: Tool
    let formats: [FileFormat]
    /// Options to run with, or `nil` when cancelled.
    let finish: (ConversionOptions?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(tool.title, systemImage: tool.systemImage)
                .font(.headline)
                .symbolRenderingMode(.hierarchical)
                .accessibilityAddTraits(.isHeader)
            Text(tool.help).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let panel = tool.panel {
                panel(formats) { options in finish(options) }
            }
            HStack {
                Spacer()
                Button("Cancel") { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Closes without changing anything.")
                    .accessibilityIdentifier("tool-panel-cancel")
            }
        }
        .padding(20)
        .frame(minWidth: 380)
        .tint(Theme.accent)
    }
}
