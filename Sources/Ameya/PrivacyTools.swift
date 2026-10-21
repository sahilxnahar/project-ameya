import AmeyaCore
import Foundation
import SwiftUI

// Privacy check, hidden-detail removal, photo details, batch rename and checksums.
// Panels: PrivacyCheckPanel.swift, PhotoDetailsPanel.swift, BatchRenamePanel.swift, ChecksumPanel.swift.

extension ToolCatalog {
    static func privacyTools(writable: Set<FileFormat>) -> [Tool] {
        let anyFiles: ([FileFormat]) -> Bool = { !$0.isEmpty }
        let photos: ([FileFormat]) -> Bool = { formats in
            formats.allSatisfy { $0.family == .image && !$0.isIcon && $0 != .pdf && $0 != .svg }
        }
        /// Files "Remove hidden details" knows how to clean (photos have their own tool).
        let cleanable: ([FileFormat]) -> Bool = { formats in
            formats.allSatisfy { PrivacyTargets.canCleanWithoutLooking($0) }
        }
        func task(_ task: FileTask, target: @escaping (FileFormat) -> FileFormat) -> (FileFormat) -> ConversionRequest {
            { format in
                var options = ConversionOptions()
                options.task = task
                return ConversionRequest(source: format, target: target(format), options: options)
            }
        }
        let keep: (FileFormat) -> FileFormat = { PrivacyTargets.sameKind($0, writable: writable) }

        return [
            Tool(id: "privacy.check", title: "Privacy check…", systemImage: "hand.raised",
                 help: "Shows what's hidden in these files before you share them, such as location, names and the device used, and can remove it.",
                 outputSuffix: "(cleaned)", isAvailable: anyFiles, makeRequest: task(.clean, target: keep),
                 panel: { _, done in AnyView(PrivacyCheckPanel(done: done)) }),
            Tool(id: "privacy.clean", title: "Remove hidden details", systemImage: "eye.slash",
                 help: "Makes a copy without the author, dates, device and other hidden details. The content stays the same.",
                 outputSuffix: "(cleaned)", isAvailable: cleanable, makeRequest: task(.clean, target: keep)),
            Tool(id: "photo.editDetails", title: "Edit details…", systemImage: "pencil.and.list.clipboard",
                 help: "Changes the date taken, title, description, author, copyright or keywords in copies of these photos.",
                 outputSuffix: "(details)", isAvailable: photos, makeRequest: task(.editDetails(PhotoDetailsEdit()), target: keep),
                 panel: { formats, done in AnyView(PhotoDetailsPanel(count: formats.count, done: done)) }),
            Tool(id: "files.rename", title: "Batch rename…", systemImage: "character.cursor.ibeam",
                 help: "Gives these files new names from a pattern, with a preview first. Makes renamed copies unless you choose otherwise.",
                 mode: .allTogether, outputSuffix: "", isAvailable: anyFiles, makeRequest: task(.inspect, target: { _ in .json }),
                 panel: { _, _ in AnyView(BatchRenamePanel()) }),
            Tool(id: "files.checksum", title: "Get checksum", systemImage: "number.square",
                 help: "Works out each file's SHA-256 fingerprint, to compare with one published by the website you got it from.",
                 outputSuffix: "(checksum)", isAvailable: anyFiles, makeRequest: task(.checksum([.sha256]), target: { _ in .json }),
                 panel: { _, _ in AnyView(ChecksumPanel(mode: .show)) }),
            Tool(id: "files.verify", title: "Verify download…", systemImage: "checkmark.shield",
                 help: "Checks a download against the checksum the website shows, so you know it arrived complete and unchanged.",
                 outputSuffix: "(checksum)", isAvailable: anyFiles, makeRequest: task(.checksum([.sha256]), target: { _ in .json }),
                 panel: { _, _ in AnyView(ChecksumPanel(mode: .verify)) }),
        ]
    }
}

enum PrivacyTargets {
    /// The output format for "the same file, cleaned": the source format when Ameya can write it
    /// (photos fall back to JPEG); otherwise `.other`, which keeps the original extension.
    static func sameKind(_ format: FileFormat, writable: Set<FileFormat>) -> FileFormat {
        switch format.family {
        case .image: writable.contains(format) && !format.isIcon ? format : .jpeg
        case .audio, .video: format == .alac ? .m4a : format
        default: format == .pdf || format == .docx ? format : .other
        }
    }

    /// Formats the worker can clean, judged from the format alone (XLSX and PPTX arrive as `.other`
    /// and are offered through the privacy check, which looks inside first).
    static func canCleanWithoutLooking(_ format: FileFormat) -> Bool {
        switch format {
        case .pdf, .docx, .mp4, .mov, .m4v, .m4a: true
        case _ where format.family == .audio || format.family == .video: FFmpegAvailability.isAvailable
        default: false
        }
    }
}

/// Runs a report-style task (privacy check, checksum) in the sandboxed worker and returns its
/// JSON, without leaving a file behind in the output folder.
@MainActor
enum ReportRunner {
    enum Problem: LocalizedError {
        case missingWorker
        var errorDescription: String? { "The converter is missing from the app bundle." }
    }

    static func run(_ url: URL, format: FileFormat, task: FileTask) async throws -> Data {
        guard let worker = Bundle.main.url(forAuxiliaryExecutable: "AmeyaWorker") else { throw Problem.missingWorker }
        var options = ConversionOptions()
        options.task = task
        let request = ConversionRequest(source: format, target: .json, options: options)
        let timeout: Duration = if case .checksum = task { .seconds(3600) } else { max(format.family.timeout, .seconds(120)) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("report.json")
        _ = try await WorkerRunner(executable: worker, timeout: timeout).run(input: url, destination: destination, request: request)
        return try Data(contentsOf: destination)
    }

    static func privacyReport(for file: PendingFile) async throws -> PrivacyReport {
        try PrivacyReport.decode(try await run(file.url, format: file.format, task: .inspect))
    }
}
