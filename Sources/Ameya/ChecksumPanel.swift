import AmeyaCore
import AppKit
import SwiftUI

/// "Get checksum" and "Verify download…". The worker reads each file in chunks and works out its
/// SHA-256 (plus SHA-1 and MD5 for older websites); verifying compares with a pasted checksum.
struct ChecksumPanel: View {
    enum Mode { case show, verify }

    let mode: Mode
    @EnvironmentObject private var store: JobStore
    @State private var files: [PendingFile] = []
    @State private var results: [UUID: Result<ChecksumReport, Error>] = [:]
    @State private var expected = ""
    @State private var showOlder = false
    @FocusState private var pasteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if mode == .verify {
                TextField("Expected checksum", text: $expected, prompt: Text("Paste the checksum from the website"))
                    .textFieldStyle(.roundedBorder)
                    .focused($pasteFocused)
                    .accessibilityHint("Paste the SHA-256, SHA-1 or MD5 checksum shown next to the download.")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(files) { file in row(file) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 100, maxHeight: 360)
            if mode == .show {
                Toggle("Also show SHA-1 and MD5 (for older websites)", isOn: $showOlder)
            }
        }
        .frame(minWidth: 480)
        .onAppear { pasteFocused = mode == .verify }
        .task { await compute() }
    }

    @ViewBuilder private func row(_ file: PendingFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(file.url.lastPathComponent, systemImage: Theme.symbol(for: file.format))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            switch results[file.id] {
            case nil:
                HStack { ProgressView().controlSize(.small); Text("Reading the file…").foregroundStyle(.secondary) }
            case .failure(let error)?:
                PanelProblem(message: (error as? LocalizedError)?.errorDescription ?? "Ameya couldn't read this file.")
            case .success(let report)?:
                if mode == .verify {
                    verdict(report)
                } else {
                    ForEach(showOlder ? ChecksumAlgorithm.allCases : [.sha256], id: \.self) { algorithm in
                        if let digest = report[algorithm] { digestRow(algorithm, digest) }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func digestRow(_ algorithm: ChecksumAlgorithm, _ digest: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(algorithm.title).font(.caption.weight(.semibold)).frame(width: 64, alignment: .leading)
            Text(digest).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(digest, forType: .string)
                Feedback.announce("\(algorithm.title) copied.")
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .accessibilityLabel("Copy \(algorithm.title)")
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func verdict(_ report: ChecksumReport) -> some View {
        if expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Ready. Paste the checksum above to compare.").foregroundStyle(.secondary)
        } else {
            let match = ChecksumMatch.compare(pasted: expected, with: report)
            let color: Color = switch match {
            case .match: .green
            case .different: .red
            case .notAChecksum: .secondary
            }
            Text(match.message)
                .foregroundStyle(color)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private func compute() async {
        files = store.pending
        for file in files {
            do {
                let data = try await ReportRunner.run(file.url, format: file.format, task: .checksum(ChecksumAlgorithm.allCases))
                results[file.id] = .success(try ChecksumReport.decode(data))
            } catch {
                results[file.id] = .failure(error)
            }
        }
        Feedback.announce(files.count == 1 ? "Checksum ready." : "Checksums ready.")
    }
}
