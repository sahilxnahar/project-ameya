import AmeyaCore
import AppKit

/// Menu bar clipboard actions: open the clipboard's picture or files in Ameya, or turn the
/// clipboard picture into JPEG/PNG/PDF and put the result back on the clipboard.
@MainActor
enum ClipboardActions {
    /// The clipboard picture is written here first; results stay while they're on the clipboard.
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Ameya Clipboard", isDirectory: true)
    }

    enum Content {
        case files([URL])
        case image(URL, FileFormat)
    }

    /// "Convert Clipboard…": opens the window with the clipboard's contents ready to convert.
    static func convertClipboard() {
        switch read() {
        case .files(let urls)?:
            AppDelegate.shared?.receive(urls)
        case .image(let url, _)?:
            AppDelegate.shared?.receive([url])
        case nil:
            explain("There's no picture or file on the clipboard.",
                    detail: "Copy a picture or a file in Finder, then try again.")
        }
    }

    /// "Copy Clipboard as JPEG/PNG/PDF": converts the clipboard picture in place.
    static func copy(as target: FileFormat) {
        let source: (URL, FileFormat)?
        switch read() {
        case .image(let url, let format)?: source = (url, format)
        case .files(let urls)?:
            source = urls.lazy.compactMap { url in FileFormat.detect(at: url).map { (url, $0) } }
                .first { $0.1.family == .image }
        case nil: source = nil
        }
        guard let (input, format) = source else {
            explain("There's no picture on the clipboard.", detail: "Copy a picture, then try again.")
            return
        }
        if format == target {
            publish(input, as: target)
            return
        }
        guard let runner = WorkerRunner.bundled(timeout: format.family.timeout) else { return }
        let destination = ClipboardImage.temporaryURL(for: target, date: Date(), in: folder) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        Task {
            do {
                _ = try await runner.run(input: input, destination: destination,
                                         request: ConversionRequest(source: format, target: target)) { _ in }
                publish(destination, as: target)
            } catch {
                explain("Ameya couldn't convert the clipboard picture to \(target.displayName).",
                        detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Reads the clipboard: file URLs win; otherwise the best image representation is saved
    /// to a temporary file so it can go through the normal converter.
    static func read(from pasteboard: NSPasteboard = .general) -> Content? {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let files = OpenedFiles.accepted(urls)
        if !files.isEmpty { return .files(files) }

        let available = pasteboard.types?.map(\.rawValue) ?? []
        guard let best = ClipboardImage.bestType(among: available),
              let data = pasteboard.data(forType: NSPasteboard.PasteboardType(best.type)) else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = ClipboardImage.temporaryURL(for: best.format, date: Date(), in: folder) {
                FileManager.default.fileExists(atPath: $0.path)
            }
            try data.write(to: url, options: .withoutOverwriting)
            return .image(url, best.format)
        } catch {
            integrationLog.error("Couldn't save clipboard picture: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Puts the file back on the clipboard both as a file (paste into Finder, Mail) and as
    /// image data (paste into documents and chats).
    private static func publish(_ url: URL, as format: FileFormat) {
        guard let data = try? Data(contentsOf: url) else { return }
        let item = NSPasteboardItem()
        if let type = format.pasteboardType { item.setData(data, forType: type) }
        item.setString(url.absoluteString, forType: .fileURL)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: "Copied as \(format.displayName)", .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// Clipboard files older than a day are no longer on anyone's clipboard.
    static func removeOldFiles() {
        let cutoff = Date().addingTimeInterval(-86_400)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: entry) }
        }
    }

    private static func explain(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }
}

private extension FileFormat {
    var pasteboardType: NSPasteboard.PasteboardType? {
        switch self {
        case .jpeg: NSPasteboard.PasteboardType("public.jpeg")
        case .png: .png
        case .pdf: .pdf
        case .tiff: .tiff
        default: nil
        }
    }
}
