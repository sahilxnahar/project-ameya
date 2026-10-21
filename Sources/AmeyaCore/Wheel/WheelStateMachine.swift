import Foundation

/// What the app saw when a drag began somewhere on the Mac.
public struct WheelDragSnapshot: Sendable, Equatable {
    /// The drag carries files (file URLs or file promises), not text or a picture.
    public var hasFiles: Bool
    /// The app the drag came from (the frontmost app when it started), if known.
    public var sourceBundleID: String?
    /// The drag started inside Ameya itself; the window handles its own drops.
    public var isInternal: Bool
    /// Keys already held when the drag started.
    public var modifiers: Set<WheelModifier>

    public init(hasFiles: Bool, sourceBundleID: String?, isInternal: Bool, modifiers: Set<WheelModifier> = []) {
        self.hasFiles = hasFiles
        self.sourceBundleID = sourceBundleID
        self.isInternal = isInternal
        self.modifiers = modifiers
    }
}

/// The wheel's life during one drag, as pure transitions so it can be tested without AppKit.
///
///     idle ──drag with files──▶ dragging ──key held──▶ showing ──drop on wedge──▶ idle (perform)
///       │                          │                    │  ▲ other key: switch wheel
///       │                          │                    │  └ key released: stays open
///       └─excluded/no files─▶ suppressed ◀──Escape──────┤
///                                  │                    └─mouse up─▶ finishing ──drop / timeout──▶ idle
///                                  └──────mouse up─────▶ idle
public struct WheelStateMachine: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case idle
        /// A file drag is under way; no key held yet.
        case dragging
        /// This drag will never show the wheel (excluded app, no files, Escape pressed …).
        case suppressed
        case showing(WheelRing, hovered: Int?)
        /// The mouse went up over the wheel; the system may still be delivering the drop.
        case finishing(WheelRing)
    }

    public enum Event: Sendable, Equatable {
        case dragStarted(WheelDragSnapshot)
        case modifiersChanged(Set<WheelModifier>)
        /// The pointer moved over a wedge (or off every wedge: `nil`).
        case hover(Int?)
        /// The system delivered the drop onto a wedge.
        case dropped(Int)
        case mouseUp
        case escape
        /// No drop arrived shortly after mouse up.
        case finishTimeout
    }

    public enum Effect: Sendable, Equatable {
        case show(WheelRing)
        case switchRing(WheelRing)
        case highlight(Int?)
        /// A gentle tick on the trackpad when the highlighted wedge changes.
        case haptic
        /// Keep the wheel up briefly in case the drop is still on its way.
        case awaitDrop
        case perform(WheelRing, wedge: Int)
        case hide
    }

    public private(set) var state: State = .idle
    public var settings: WheelSettings

    public init(settings: WheelSettings = WheelSettings()) {
        self.settings = settings
    }

    public var isWheelVisible: Bool {
        switch state {
        case .showing, .finishing: true
        default: false
        }
    }

    /// A drag is being tracked (the app polls keys only while this is true).
    public var isTracking: Bool { state != .idle }

    @discardableResult
    public mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case let (.idle, .dragStarted(snapshot)), let (.finishing, .dragStarted(snapshot)):
            let hide: [Effect] = state == .idle ? [] : [.hide]
            guard settings.isEnabled, snapshot.hasFiles, !snapshot.isInternal,
                  !settings.exclusions.excludes(snapshot.sourceBundleID) else {
                state = .suppressed
                return hide
            }
            state = .dragging
            return hide + handle(.modifiersChanged(snapshot.modifiers))

        case let (.dragging, .modifiersChanged(held)):
            guard let ring = settings.mapping.ring(for: held) else { return [] }
            state = .showing(ring, hovered: nil)
            return [.show(ring)]

        case let (.showing(current, _), .modifiersChanged(held)):
            // Letting go of the key keeps the wheel open; pressing another key switches wheels.
            guard let ring = settings.mapping.ring(for: held), ring != current else { return [] }
            state = .showing(ring, hovered: nil)
            return [.switchRing(ring)]

        case let (.showing(ring, hovered), .hover(wedge)):
            guard wedge != hovered else { return [] }
            state = .showing(ring, hovered: wedge)
            return wedge == nil ? [.highlight(nil)] : [.highlight(wedge), .haptic]

        case let (.showing(ring, _), .dropped(wedge)), let (.finishing(ring), .dropped(wedge)):
            state = .idle
            return [.perform(ring, wedge: wedge), .hide]

        case let (.showing(ring, _), .mouseUp):
            state = .finishing(ring)
            return [.awaitDrop]

        case (.showing, .escape):
            state = .suppressed
            return [.hide]

        case (.finishing, .finishTimeout):
            state = .idle
            return [.hide]

        case (.dragging, .escape):
            state = .suppressed
            return []

        case (.dragging, .mouseUp), (.suppressed, .mouseUp):
            state = .idle
            return []

        default:
            return []
        }
    }
}
