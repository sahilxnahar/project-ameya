import AmeyaCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject private var store: JobStore
    @State private var isTargeted = false
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            dropZone
            if !store.pending.isEmpty { targetPicker }
            if !store.unsupported.isEmpty {
                Label("Not supported yet: \(store.unsupported.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            if !store.jobs.isEmpty { jobList }
        }
        .padding(20)
        .frame(width: 460)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image, .pdf], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { store.add(urls) }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Drop images or PDFs here")
                .font(.headline)
            Button("Choose Files…") { isImporting = true }
                .keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        )
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            store.add(urls)
            return !urls.isEmpty
        } isTargeted: { isTargeted = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop zone. Drop images or PDFs, or choose files.")
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(store.pending.count == 1 ? store.pending[0].url.lastPathComponent : "\(store.pending.count) files")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Clear", role: .cancel) { store.clearPending() }
                    .buttonStyle(.borderless)
            }
            if store.targets.isEmpty {
                Text("These files have no conversion in common. Convert them separately.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Convert to").font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(store.targets) { target in
                        TargetButton(target: target, notes: store.possibleLosses(to: target)) {
                            store.convert(to: target)
                        }
                    }
                }
            }
        }
    }

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Results").font(.headline)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.open(store.outputDirectory) }
                    .buttonStyle(.borderless)
                Button("Clear Finished") { store.clearFinished() }
                    .buttonStyle(.borderless)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.jobs) { job in
                        JobRow(job: job) { store.cancel(job) }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }
}

private struct TargetButton: View {
    let target: FileFormat
    let notes: [ConversionNote]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(target.displayName).font(.body.weight(.medium))
                if !notes.isEmpty {
                    Image(systemName: "info.circle").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .help(notes.isEmpty ? "Convert to \(target.displayName)" : notes.map(\.message).joined(separator: "\n"))
        .accessibilityHint(notes.map(\.message).joined(separator: " "))
    }
}

private struct JobRow: View {
    @ObservedObject var job: Job
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusIcon.frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.destination.lastPathComponent).lineLimit(1).truncationMode(.middle)
                detail.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView(value: job.progress).progressViewStyle(.circular).controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var detail: some View {
        switch job.state {
        case .queued: Text("Waiting…")
        case .running: Text("Converting \(job.source.lastPathComponent)…")
        case .done(let result):
            let size = ByteCountFormatter.string(fromByteCount: Int64(result.outputBytes), countStyle: .file)
            Text(([size] + result.notes.map(\.message)).joined(separator: " · "))
        case .failed(let message): Text(message)
        case .cancelled: Text("Cancelled")
        }
    }

    @ViewBuilder private var actions: some View {
        switch job.state {
        case .queued, .running:
            Button("Cancel", action: cancel).buttonStyle(.borderless)
        case .done:
            Button("Open") { NSWorkspace.shared.open(job.destination) }.buttonStyle(.borderless)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([job.destination])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")
        case .failed, .cancelled:
            EmptyView()
        }
    }
}
