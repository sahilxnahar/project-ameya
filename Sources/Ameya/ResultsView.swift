import AmeyaCore
import AppKit
import SwiftUI

/// Finished and running jobs, newest first, with the batch headline on top.
struct ResultsSection: View {
    @EnvironmentObject private var store: JobStore
    @EnvironmentObject private var results: ResultsModel
    @Binding var preview: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "Results")
                Spacer()
                Button("Clear Finished") {
                    store.clearFinished()
                    results.dismissSummary()
                }
                .buttonStyle(.borderless)
                .disabled(!store.jobs.contains { $0.state.isFinished })
                .accessibilityHint("Removes finished rows from this list. Your files stay where they are.")
                .accessibilityIdentifier("clear-finished")
            }
            if let summary = results.summary {
                BatchBanner(summary: summary, celebrations: results.celebrations)
                    .transition(Theme.cardTransition(reduceMotion: reduceMotion))
            }
            VStack(spacing: 6) {
                ForEach(store.jobs) { job in
                    JobRow(job: job, preview: $preview) { store.cancel(job) }
                        .transition(Theme.cardTransition(reduceMotion: reduceMotion))
                }
            }
        }
        .animation(Theme.arrival(reduceMotion: reduceMotion), value: store.jobs.map(\.id))
        .animation(Theme.arrival(reduceMotion: reduceMotion), value: results.summary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("results")
    }
}

/// "Done! 4 files, 12 MB smaller" — with a playful check and, if allowed, a confetti burst.
private struct BatchBanner: View {
    let summary: BatchSummary
    let celebrations: Int
    @AppStorage(Preferences.celebrateKey) private var celebrate = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pop = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: summary.isCelebration ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(summary.isCelebration ? Theme.accent : .orange)
                .symbolRenderingMode(.hierarchical)
                .scaleEffect(pop ? 1.18 : 1)
                .accessibilityHidden(true)
            Text(summary.headline)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .card(highlighted: summary.isCelebration)
        .overlay {
            if CelebrationPolicy.shouldCelebrate(setting: celebrate, reduceMotion: reduceMotion, summary: summary) {
                ConfettiBurst(trigger: celebrations).frame(height: 220).offset(y: -40)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("batch-summary")
        .onChange(of: celebrations) { _, _ in bounce() }
        .onAppear(perform: bounce)
    }

    private func bounce() {
        guard !reduceMotion, summary.isCelebration else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { pop = true }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.18)) { pop = false }
    }
}

struct JobRow: View {
    @ObservedObject var job: Job
    @Binding var preview: URL?
    let cancel: () -> Void
    @EnvironmentObject private var results: ResultsModel
    @Environment(\.accessibilityDifferentiateWithoutColor) private var noColor
    @FocusState private var focused: Bool
    @State private var problem: String?

    private var isUndone: Bool { results.undone.contains(job.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.destination.lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(isUndone)
                detail
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            actions
        }
        .padding(10)
        .card(highlighted: focused)
        .focusable()
        .focused($focused)
        .onKeyPress(.space) {
            guard isOpenable else { return .ignored }
            preview = job.destination
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(job.destination.lastPathComponent), \(statusWord)")
        .accessibilityHint(isOpenable ? "Press Space to preview with Quick Look." : "")
        .accessibilityIdentifier("job-row")
    }

    private var isOpenable: Bool {
        if case .done = job.state, !isUndone { return true }
        return false
    }

    private var statusWord: String {
        if isUndone { return "moved to the Trash" }
        switch job.state {
        case .queued: return "waiting"
        case .running: return "working, \(Int(job.progress * 100)) percent"
        case .done: return "done"
        case .failed: return "didn't work"
        case .cancelled: return "cancelled"
        }
    }

    @ViewBuilder private var statusIcon: some View {
        Group {
            if isUndone {
                Image(systemName: "trash.circle").foregroundStyle(.secondary)
            } else {
                switch job.state {
                case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }
            }
        }
        .font(.title3)
        .symbolRenderingMode(.hierarchical)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var detail: some View {
        Group {
            if isUndone {
                Text("Moved to the Trash. You can put it back from there.")
            } else {
                switch job.state {
                case .queued: Text(noColor ? "Waiting · next in line" : "Next in line…")
                case .running:
                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.activity)
                        ProgressView(value: job.progress).controlSize(.small).accessibilityHidden(true)
                    }
                case .done(let result): doneDetail(result)
                case .failed(let message): Text((noColor ? "Didn't work: " : "") + message)
                case .cancelled: Text("Cancelled")
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func doneDetail(_ result: ConversionResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let change = job.sizeChange {
                HStack(spacing: 4) {
                    if noColor { Text("Done ·") }
                    Text(change.sizes)
                    Text("·")
                    Text(change.description).fontWeight(.semibold).foregroundStyle(.primary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(change.spoken)
            } else if let names = result.outputNames {
                Text("\(names.count) file\(names.count == 1 ? "" : "s") in a folder")
            } else {
                Text(SizeChange.format(Int64(result.outputBytes)))
            }
            ForEach(result.notes, id: \.self) { note in
                Label(note.message, systemImage: "info.circle").font(.caption)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 2) {
            switch job.state {
            case .queued, .running:
                Button("Cancel", action: cancel)
                    .accessibilityHint("Stops this one. Nothing is saved.")
                    .accessibilityIdentifier("cancel-job")
            case .done where !isUndone:
                // Opening a folder shows it in Finder.
                Button(job.isFolder ? "Show" : "Open") { NSWorkspace.shared.open(job.destination) }
                .accessibilityLabel(job.isFolder ? "Show folder" : "Open")
                .accessibilityHint("Opens \(job.destination.lastPathComponent).")
                .accessibilityIdentifier("open-result")
                iconButton("eye", label: "Quick Look", hint: "Previews it without opening an app. Shortcut: Space.", id: "quick-look") {
                    preview = job.destination
                }
                iconButton("folder", label: "Show in Finder", hint: "Shows where it was saved.", id: "show-in-finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([job.destination])
                }
                iconButton("arrow.uturn.backward", label: "Undo", hint: "Moves the new file to the Trash. Your original is not touched.", id: "undo") {
                    problem = results.undo(job)
                }
                .disabled(!results.canUndo(job))
            default:
                EmptyView()
            }
        }
        .buttonStyle(.borderless)
    }

    private func iconButton(_ symbol: String, label: String, hint: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 22)
        }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityIdentifier(id)
    }
}
