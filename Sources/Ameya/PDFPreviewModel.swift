import AmeyaCore
import AppKit
import SwiftUI

/// What the page panels know about the pending PDF. The app never opens the PDF: the sandboxed
/// worker reads it and sends back its page count, page sizes and small page images (PDFPreviewInfo),
/// which land in a private temporary folder that is removed when the panel closes.
@MainActor
final class PDFPreviewModel: ObservableObject {
    enum State: Equatable {
        case loading
        case ready(PDFPreviewInfo)
        /// Nothing to show; the text says why.
        case problem(String)
    }

    @Published private(set) var state: State = .loading
    private var folder: URL?
    private var started = false

    /// The preview worker is stopped after this long.
    static let timeout: Duration = .seconds(60)

    var info: PDFPreviewInfo? {
        if case .ready(let info) = state { return info }
        return nil
    }

    var pageCount: Int { info?.pageCount ?? 0 }

    /// Asks the worker about `url`. Cancelling the surrounding task (the panel closing) stops the worker.
    func load(_ url: URL?, thumbnails: Bool = true) async {
        guard !started else { return }
        started = true
        guard let url, let worker = Bundle.main.url(forAuxiliaryExecutable: "AmeyaWorker") else {
            state = .problem(Self.cannotOpen)
            return
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ameya-preview-\(UUID().uuidString)", isDirectory: true)
        let side = thumbnails ? PDFPreviewInfo.defaultThumbnailSide : 0
        let request = ConversionRequest(source: .pdf, target: .pdf,
                                        options: ConversionOptions(pdf: .preview(password: "", thumbnailSide: side)))
        do {
            let runner = WorkerRunner(executable: worker, timeout: Self.timeout)
            _ = try await runner.run(inputs: [url], destination: destination, request: request)
            folder = destination
            state = Self.interpret(destination)
        } catch WorkerError.cancelled {
            cleanUp()
        } catch {
            integrationLog.error("PDF preview failed: \(error.localizedDescription, privacy: .public)")
            state = .problem(Self.cannotOpen)
        }
        if Task.isCancelled { cleanUp() }
    }

    /// The image for `page` (1-based), read from the worker's output when first asked for.
    func thumbnail(_ page: Int) async -> NSImage? {
        guard let folder, let info, page >= 1, page <= info.thumbnailCount else { return nil }
        let file = folder.appendingPathComponent(PDFPreviewInfo.thumbnailName(page))
        let data = await Task.detached { Self.readSmallFile(file) }.value
        return data.flatMap { Self.isPNG($0) ? NSImage(data: $0) : nil }
    }

    /// Removes the temporary folder. Safe to call more than once.
    func cleanUp() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    // MARK: Reading the worker's answer

    static let cannotOpen = "Ameya couldn't open this PDF to show its pages."
    static let lockedMessage = "This PDF has a password. Use “Remove password…” first."

    private static func interpret(_ folder: URL) -> State {
        guard let data = readSmallFile(folder.appendingPathComponent(PDFPreviewInfo.fileName)),
              let info = try? JSONDecoder().decode(PDFPreviewInfo.self, from: data), info.isConsistent else {
            return .problem(cannotOpen)
        }
        if info.locked { return .problem(lockedMessage) }
        if info.pageCount == 0 { return .problem("This PDF has no pages.") }
        return .ready(info)
    }

    /// A file's bytes, or `nil` when it is missing or larger than the worker is allowed to send.
    private nonisolated static func readSmallFile(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = try? handle.read(upToCount: PDFPreviewInfo.maxFileBytes + 1)
        guard let data, data.count <= PDFPreviewInfo.maxFileBytes else { return nil }
        return data
    }

    private nonisolated static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }
}
