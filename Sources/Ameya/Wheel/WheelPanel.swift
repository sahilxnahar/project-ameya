import AmeyaCore
import AppKit
import SwiftUI

/// The floating, borderless window the wheel lives in. It never activates Ameya or takes
/// keyboard focus, so the app the user is dragging from stays in front.
final class WheelPanel: NSPanel {
    let dropView: WheelDropView

    init(model: WheelViewModel) {
        dropView = WheelDropView(model: model)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // The wheel draws its own.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        contentView = dropView
        setAccessibilityRole(.popover)
        setAccessibilityLabel("Ameya drag wheel")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the wheel centred on `point` (screen coordinates), kept fully on that screen.
    func show(centeredAt point: NSPoint, diameter: Double) {
        let side = CGFloat(diameter)
        var frame = NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - side)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - side)
        }
        setFrame(frame, display: true)
        alphaValue = 1
        orderFrontRegardless()
    }

    /// Fades out. Reduce Motion users get a quick fade too; it is not motion.
    func dismiss() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.orderOut(nil)
            }
        })
    }
}

/// Hosts the SwiftUI wheel and is the drop target. Dropping onto a wedge lets the system hand
/// the files to the sandboxed app with read access, exactly as a drop on the main window does.
final class WheelDropView: NSView {
    private let model: WheelViewModel
    private let host: NSHostingView<WheelView>
    /// Called with the wedge under the pointer while a drag moves over the wheel.
    var onHover: ((Int?) -> Void)?
    /// Called with the wedge and the dropped files.
    var onDrop: ((Int, [URL]) -> Void)?

    init(model: WheelViewModel) {
        self.model = model
        host = NSHostingView(rootView: WheelView(model: model))
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
        registerForDraggedTypes(WheelPasteboard.acceptedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func wedge(at windowPoint: NSPoint) -> Int? {
        let local = convert(windowPoint, from: nil)
        // NSView is y-up unless flipped, matching WheelGeometry.
        let dy = isFlipped ? bounds.midY - local.y : local.y - bounds.midY
        return model.geometry.wedge(dx: Double(local.x - bounds.midX), dy: Double(dy))
    }

    /// Prefer a copy so the source never thinks its files moved away. Finder narrows the
    /// allowed operations while ⌘ or ⌥ is held, so fall back to whatever it allows.
    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard wedge(at: sender.draggingLocation) != nil else { return [] }
        let allowed = sender.draggingSourceOperationMask
        for candidate: NSDragOperation in [.copy, .generic, .link, .move] where allowed.contains(candidate) {
            return candidate
        }
        return []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onHover?(wedge(at: sender.draggingLocation))
        return operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onHover?(wedge(at: sender.draggingLocation))
        return operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHover?(nil)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        wedge(at: sender.draggingLocation) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = wedge(at: sender.draggingLocation) else { return false }
        let pasteboard = sender.draggingPasteboard
        WheelPasteboard.receive(pasteboard) { [weak self] urls in
            self?.onDrop?(index, urls)
        }
        return true
    }
}
