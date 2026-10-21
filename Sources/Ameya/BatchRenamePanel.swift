import AmeyaCore
import SwiftUI

/// "Batch rename…": a pattern with tokens, find/replace and a case change, with a live preview.
/// Makes renamed copies in the output folder unless the user chooses to rename in place.
struct BatchRenamePanel: View {
    @EnvironmentObject private var store: JobStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var history = RenameHistory.shared
    @State private var rule = RenameRule(pattern: "{name}")
    @State private var inPlace = false
    @State private var facts: [URL: PrivacyReport.Facts] = [:]
    @State private var readingDetails = false
    @State private var outcome: String?

    static let tokens: [(title: String, token: String)] = [
        ("Original name", "{name}"), ("Number (001)", "{n:3}"), ("Date taken", "{date taken:yyyy-MM-dd}"),
        ("Date modified", "{date modified:yyyy-MM-dd}"), ("Width × height", "{width}x{height}"), ("Camera", "{camera}"),
    ]

    private var files: [PendingFile] { store.pending }
    private var folder: URL? { RenameApplier.commonFolder(files.map(\.url)) }

    private var newNames: [String] {
        let items = files.map { file in
            RenameItem(name: file.url.lastPathComponent,
                       dateModified: (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                       facts: facts[file.url])
        }
        let ownNames = Set(files.map { $0.url.lastPathComponent.lowercased() })
        let directory = inPlace ? folder : store.outputDirectory
        return RenamePlanner.newNames(for: items, rule: rule) { name in
            guard let directory else { return false }
            if inPlace && ownNames.contains(name.lowercased()) { return false } // freed up as the batch moves
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Pattern", text: $rule.pattern, prompt: Text("For example Holiday {n:3}"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Name pattern")
                    .accessibilityHint("Words in braces are filled in for each file, such as {n:3} for 001, 002.")
                Menu("Insert") {
                    ForEach(Self.tokens, id: \.token) { item in
                        Button(item.title) { rule.pattern += item.token }
                    }
                }
                .fixedSize()
                .accessibilityHint("Adds a part that changes for each file.")
            }
            HStack {
                TextField("Find", text: $rule.find, prompt: Text("Find")).textFieldStyle(.roundedBorder)
                TextField("Replace with", text: $rule.replace, prompt: Text("Replace with")).textFieldStyle(.roundedBorder)
            }
            HStack {
                Picker("Letters", selection: $rule.caseChange) {
                    ForEach(RenameRule.CaseChange.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Stepper("Start at \(rule.startNumber)", value: $rule.startNumber, in: 0...99_999)
            }
            Toggle("Rename the originals instead of making copies", isOn: $inPlace)
                .disabled(folder == nil)
                .help(folder == nil ? "Only works when all the files are in one folder." : "You'll be asked to allow access to their folder.")
            preview
            if let outcome {
                Text(outcome).font(.callout).accessibilityAddTraits(.updatesFrequently)
            }
            HStack {
                if !history.last.isEmpty {
                    Button("Undo Rename") {
                        let result = history.undo()
                        outcome = "Put back \(result.done) name\(result.done == 1 ? "" : "s")."
                            + (result.failed.isEmpty ? "" : " Couldn't put back: \(result.failed.joined(separator: ", ")).")
                        Feedback.announce(outcome ?? "")
                    }
                    .accessibilityHint("Gives the renamed files their old names back.")
                }
                Spacer()
                Button(inPlace ? "Rename \(files.count) Files" : "Make \(files.count) Renamed Copies") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(files.isEmpty || readingDetails)
                    .accessibilityIdentifier("rename-apply")
            }
        }
        .frame(minWidth: 480)
        .task(id: RenamePlanner.needsFacts(rule.pattern)) { await loadFactsIfNeeded() }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preview").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if readingDetails {
                HStack { ProgressView().controlSize(.small); Text("Reading photo details…").foregroundStyle(.secondary) }
            }
            let names = newNames
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(zip(files, names).enumerated()), id: \.offset) { _, pair in
                        HStack(spacing: 6) {
                            Text(pair.0.url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "arrow.right").foregroundStyle(Theme.accent).accessibilityHidden(true)
                            Text(pair.1).lineLimit(1).truncationMode(.middle)
                        }
                        .font(.callout)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(pair.0.url.lastPathComponent) becomes \(pair.1)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 80, maxHeight: 200)
            .padding(8)
            .card()
        }
    }

    // MARK: Actions

    /// Photo tokens need details from inside the files, which are read in the sandboxed worker.
    private func loadFactsIfNeeded() async {
        guard RenamePlanner.needsFacts(rule.pattern) else { return }
        let missing = files.filter { facts[$0.url] == nil && $0.format.family == .image }
        guard !missing.isEmpty else { return }
        readingDetails = true
        for file in missing {
            if let report = try? await ReportRunner.privacyReport(for: file) { facts[file.url] = report.facts }
        }
        readingDetails = false
    }

    private func apply() {
        let urls = files.map(\.url)
        let names = newNames
        if inPlace {
            guard let granted = RenameApplier.requestFolder(for: urls) else {
                outcome = "Nothing was renamed: Ameya needs you to choose the folder the files are in."
                return
            }
            let result = RenameApplier.renameInPlace(urls, as: names, grantedFolder: granted)
            outcome = "Renamed \(result.done) file\(result.done == 1 ? "" : "s")."
                + (result.failed.isEmpty ? "" : " Couldn't rename: \(result.failed.joined(separator: ", ")).")
            Feedback.play(result.failed.isEmpty ? .done : .problem)
            Feedback.announce(outcome ?? "")
            store.clearPending() // the old names no longer exist
        } else {
            let result = RenameApplier.copy(urls, as: names, into: store.outputDirectory)
            let message = "Made \(result.done) renamed cop\(result.done == 1 ? "y" : "ies") in \(MainView.friendlyPath(store.outputDirectory))."
                + (result.failed.isEmpty ? "" : " Couldn't copy: \(result.failed.joined(separator: ", ")).")
            Feedback.play(result.failed.isEmpty ? .done : .problem)
            Feedback.announce(message)
            if result.failed.isEmpty { dismiss() } else { outcome = message }
        }
    }
}
