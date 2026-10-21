import AmeyaCore
import SwiftUI

/// "What's hidden in this file?" Each pending file is read in the sandboxed worker; the findings
/// are grouped by how personal they are, with a plain explanation of who could see them.
/// "Remove these" makes cleaned copies of every file that can be cleaned.
struct PrivacyCheckPanel: View {
    let done: (ConversionOptions) -> Void
    @EnvironmentObject private var store: JobStore
    @Environment(\.dismiss) private var dismiss
    @State private var results: [UUID: Result<PrivacyReport, Error>] = [:]
    @State private var files: [PendingFile] = []

    private var finished: Bool { results.count == files.count && !files.isEmpty }
    private var cleanable: [PendingFile] {
        files.filter { file in
            if case .success(let report)? = results[file.id] { return report.canClean && !report.findings.isEmpty }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(files) { file in fileSection(file) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220, maxHeight: 460)
            if finished { summary }
        }
        .frame(minWidth: 460)
        .task { await check() }
    }

    // MARK: Pieces

    @ViewBuilder private func fileSection(_ file: PendingFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(file.url.lastPathComponent, systemImage: Theme.symbol(for: file.format))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            switch results[file.id] {
            case nil:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking inside…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            case .failure(let error)?:
                PanelProblem(message: (error as? LocalizedError)?.errorDescription ?? "Ameya couldn't read this file.")
            case .success(let report)?:
                reportView(report)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder private func reportView(_ report: PrivacyReport) -> some View {
        if report.findings.isEmpty {
            Label(report.kind == .other ? "Nothing Ameya knows how to read." : "Nothing hidden found. Safe to share!",
                  systemImage: report.kind == .other ? "questionmark.circle" : "checkmark.seal.fill")
                .foregroundStyle(report.kind == .other ? Color.secondary : Color.green)
        }
        ForEach(report.grouped, id: \.group) { entry in
            VStack(alignment: .leading, spacing: 4) {
                Label(entry.group.title, systemImage: entry.group.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(entry.group == .location || entry.group == .name ? Theme.accent : .primary)
                Text(entry.group.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(entry.findings.enumerated()), id: \.offset) { _, finding in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(finding.label + ":").foregroundStyle(.secondary)
                        Text(finding.value).textSelection(.enabled)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(finding.label): \(finding.value)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(entry.group.title)
        }
        ForEach(report.kept, id: \.self) { note in
            Label(note, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: some View {
        HStack {
            Text(summaryText).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Remove These") { remove() }
                .keyboardShortcut(.defaultAction)
                .disabled(cleanable.isEmpty)
                .accessibilityHint("Makes cleaned copies in your output folder. Your originals aren't changed.")
                .accessibilityIdentifier("privacy-remove")
        }
    }

    private var summaryText: String {
        let total = files.reduce(0) { count, file in
            if case .success(let report)? = results[file.id] { return count + report.findings.count }
            return count
        }
        if total == 0 { return "Nothing to remove." }
        let which = cleanable.count == files.count ? "" : " \(cleanable.count) of \(files.count) files can be cleaned."
        return "\(total) hidden detail\(total == 1 ? "" : "s") found.\(which)"
    }

    // MARK: Actions

    private func check() async {
        files = store.pending
        for file in files {
            do {
                results[file.id] = .success(try await ReportRunner.privacyReport(for: file))
            } catch {
                results[file.id] = .failure(error)
            }
        }
        let total = files.compactMap { try? results[$0.id]?.get().findings.count }.reduce(0, +)
        Feedback.announce(total == 0 ? "Privacy check done. Nothing hidden was found." : "Privacy check done. \(total) hidden details found.")
    }

    private func remove() {
        var options = ConversionOptions()
        options.task = .clean
        if cleanable.count == store.pending.count {
            done(options) // the usual path: one cleaned copy per pending file
            return
        }
        // Only some can be cleaned: run those, and leave the rest waiting.
        guard let tool = store.catalog.tools.first(where: { $0.id == "privacy.check" }) else { return }
        store.runNow(tool, on: cleanable.map(\.url))
        for file in cleanable { store.remove(file) }
        dismiss()
    }
}
