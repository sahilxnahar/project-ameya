import AmeyaCore
import AppKit
import Carbon.HIToolbox
import os

private let wheelLog = Logger(subsystem: "io.github.sahilxnahar.ameya", category: "wheel")

/// Watches for file drags anywhere on the Mac and shows the wheel while a key is held.
///
/// How it notices a drag, with public APIs and no Accessibility permission:
/// - A global monitor for left mouse down / dragged / up. Global *mouse* monitors need no
///   permission (key monitors would). It only observes; events still reach their app untouched.
/// - When a drag begins, the source app writes to the shared drag pasteboard, so its
///   `changeCount` moves. A change since the mouse went down, with file URL or file promise
///   types on it, means files are being dragged.
/// - Only while that drag lasts, a 30 Hz timer reads the held modifier keys
///   (`NSEvent.modifierFlags`), the mouse button, and Escape. No timer runs otherwise, so the
///   wheel costs nothing when the user isn't dragging files.
///
/// The drop itself is an ordinary drag and drop onto the wheel's window (`WheelDropView`), so the
/// system grants the sandboxed app access to exactly the dropped files.
@MainActor
final class WheelController {
    static let shared = WheelController()

    private var machine = WheelStateMachine()
    private let model = WheelViewModel()
    private lazy var panel: WheelPanel = makePanel()
    private var monitor: Any?
    private var defaultsObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var finishWork: DispatchWorkItem?

    private var dragChangeCount = 0
    private var armed = false
    private var lastPasteboardCheck = Date.distantPast
    /// Formats guessed when the drag began; the wedges are built from these.
    private var dragFormats: [FileFormat] = []
    private var lastModifiers: Set<WheelModifier> = []
    /// Set by `--wheel-preview`; ignores real drags while the preview is up.
    private var isPreviewing = false

    private init() {}

    // MARK: Lifecycle

    func start() {
        reloadSettings()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSettings() }
        }
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handleGlobal(type) }
        }
        wheelLog.info("Drag wheel monitor installed: \(self.monitor != nil, privacy: .public)")
    }

    private func reloadSettings() {
        let settings = WheelSettings.load(from: .standard)
        guard settings != machine.settings else { return }
        machine.settings = settings
        model.size = settings.size
        model.mapping = settings.mapping
    }

    // MARK: Detecting a drag

    private func handleGlobal(_ type: NSEvent.EventType) {
        guard !isPreviewing else { return }
        switch type {
        case .leftMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            armed = true
        case .leftMouseDragged:
            guard armed, machine.state == .idle else { return }
            // Dragging fires many events; the pasteboard check is an IPC call, so throttle it.
            let now = Date()
            guard now.timeIntervalSince(lastPasteboardCheck) > 0.05 else { return }
            lastPasteboardCheck = now
            let pasteboard = NSPasteboard(name: .drag)
            guard pasteboard.changeCount != dragChangeCount else { return }
            armed = false
            beginDrag(pasteboard)
        case .leftMouseUp:
            armed = false
            if machine.isTracking { apply(machine.handle(.mouseUp)) }
        default:
            break
        }
    }

    private func beginDrag(_ pasteboard: NSPasteboard) {
        let front = NSWorkspace.shared.frontmostApplication
        let hasFiles = WheelPasteboard.hasFiles(pasteboard)
        dragFormats = hasFiles ? WheelPasteboard.predictedFormats(pasteboard) : []
        lastModifiers = Self.heldModifiers()
        let snapshot = WheelDragSnapshot(
            hasFiles: hasFiles && !dragFormats.isEmpty,
            sourceBundleID: front?.bundleIdentifier,
            isInternal: front?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
            modifiers: lastModifiers
        )
        apply(machine.handle(.dragStarted(snapshot)))
        if machine.isTracking { startPolling() }
    }

    /// Runs only while a drag is tracked: modifier keys, mouse release and Escape.
    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard machine.isTracking else {
            stopPolling()
            return
        }
        if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape)) {
            apply(machine.handle(.escape))
        }
        let held = Self.heldModifiers()
        if held != lastModifiers {
            lastModifiers = held
            apply(machine.handle(.modifiersChanged(held)))
        }
        // The global mouse-up can be swallowed by the drag session, so check the button too.
        if NSEvent.pressedMouseButtons & 1 == 0 {
            if case .finishing = machine.state { return } // Already waiting for the drop.
            apply(machine.handle(.mouseUp))
        }
    }

    static func heldModifiers() -> Set<WheelModifier> {
        let flags = NSEvent.modifierFlags
        var held: Set<WheelModifier> = []
        if flags.contains(.shift) { held.insert(.shift) }
        if flags.contains(.command) { held.insert(.command) }
        if flags.contains(.control) { held.insert(.control) }
        if flags.contains(.option) { held.insert(.option) }
        return held
    }

    // MARK: Effects

    private func apply(_ effects: [WheelStateMachine.Effect]) {
        for effect in effects {
            switch effect {
            case let .show(ring):
                present(ring, at: NSEvent.mouseLocation)
            case let .switchRing(ring):
                fill(ring)
                announce(ring.announcement(choices: model.choices.count))
            case let .highlight(index):
                model.hovered = index
            case .haptic:
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            case .awaitDrop:
                scheduleFinish(after: 0.6)
            case .perform:
                break // The files arrive with the drop; `drop(_:urls:)` carries out the choice.
            case .hide:
                finishWork?.cancel()
                panel.dismiss()
                model.hovered = nil
            }
        }
        if !machine.isTracking { stopPolling() }
    }

    private func present(_ ring: WheelRing, at point: NSPoint) {
        fill(ring)
        model.hovered = nil
        model.openCount += 1
        panel.show(centeredAt: point, diameter: model.diameter)
        announce(ring.announcement(choices: model.choices.count))
    }

    private func fill(_ ring: WheelRing) {
        guard let store = AppDelegate.shared?.store else { return }
        model.ring = ring
        model.fileCount = dragFormats.count
        model.choices = WheelChoices.make(ring, formats: dragFormats, store: store)
        model.hovered = nil
    }

    private func scheduleFinish(after seconds: Double) {
        finishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.apply(self.machine.handle(.finishTimeout))
            }
        }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    // MARK: Panel callbacks

    private func makePanel() -> WheelPanel {
        let panel = WheelPanel(model: model)
        panel.dropView.onHover = { [weak self] index in
            guard let self, !self.isPreviewing else { return }
            self.apply(self.machine.handle(.hover(index)))
        }
        panel.dropView.onDrop = { [weak self] index, urls in
            self?.drop(index, urls: urls)
        }
        return panel
    }

    private func drop(_ index: Int, urls: [URL]) {
        guard model.choices.indices.contains(index) else { return }
        let choice = model.choices[index]
        let effects = machine.handle(.dropped(index))
        guard effects.contains(where: { if case .perform = $0 { true } else { false } }) else { return }
        apply(effects)
        guard let delegate = AppDelegate.shared else { return }
        let message = WheelChoices.perform(choice, on: urls, delegate: delegate)
        wheelLog.info("Wheel: \(choice.id, privacy: .public) on \(urls.count, privacy: .public) file(s)")
        if !message.isEmpty { announce(message) }
    }

    // MARK: Preview (`--wheel-preview [convert|tools|actions]`)

    /// Shows the wheel at the centre of the screen with sample files for five seconds, with one
    /// wedge highlighted, then quits. For screenshots and checking the look without a real drag.
    func showPreview(_ ring: WheelRing, quitAfter seconds: Double = 5) {
        isPreviewing = true
        dragFormats = switch ring {
        case .convert, .actions: [.heic, .heic, .heic]
        case .tools: [.jpeg, .png]
        }
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        present(ring, at: NSPoint(x: screen.midX, y: screen.midY))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.hovered = min(1, self.model.choices.count - 1)
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
        // A picture of the wheel, for docs and for checking without Screen Recording permission.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.writeSnapshot(ring) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    /// Draws the wheel's window into a PNG in the app's temporary folder and prints its path.
    private func writeSnapshot(_ ring: WheelRing) {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-wheel-preview-\(ring.rawValue).png")
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil else { return }
        print("WHEEL PREVIEW \(url.path)")
    }

    static func previewRing(from arguments: [String]) -> WheelRing? {
        guard let index = arguments.firstIndex(of: "--wheel-preview") else { return nil }
        let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
        return WheelRing(rawValue: next) ?? .convert
    }
}
