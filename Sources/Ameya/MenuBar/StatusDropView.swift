import AppKit

/// Takes file drags onto the menu bar icon. Clicks pass through to the button underneath.
///
/// The dropped files come with sandbox access, like any drag and drop: the system extends the
/// sandbox to exactly those files when the drop is accepted.
@MainActor
final class StatusDropView: NSView, NSWindowDelegate {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL]

    var onHover: (Bool) -> Void = { _ in }
    var onDrop: ([URL]) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Self.types)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clicks go to the status bar button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // NSView and NSWindowDelegate share the same dragging methods, so both routes land here.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty else { return [] }
        onHover(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(sender).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHover(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !urls(sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let dropped = urls(sender)
        onHover(false)
        guard !dropped.isEmpty else { return false }
        onDrop(dropped)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onHover(false)
    }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
