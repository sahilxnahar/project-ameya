import AppKit
import SwiftUI

/// Optional sounds (off by default) and VoiceOver announcements.
@MainActor
enum Feedback {
    enum Sound: String {
        case added = "Pop"
        case done = "Glass"
        case problem = "Basso"
    }

    /// Built-in macOS sounds, only when the user turned sounds on in Settings.
    static func play(_ sound: Sound) {
        guard Preferences.playSounds else { return }
        NSSound(named: NSSound.Name(sound.rawValue))?.play()
    }

    static func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

/// A short, quiet burst of confetti from the top of the results. Purely decorative: it never
/// takes clicks, is hidden from VoiceOver, and isn't shown with Reduce Motion.
struct ConfettiBurst: View {
    let trigger: Int
    @State private var start: Date?
    private let duration: TimeInterval = 1.4
    @State private var pieces: [Piece] = (0..<44).map { _ in Piece() }

    struct Piece {
        let angle = Double.random(in: -.pi * 0.95 ... -.pi * 0.05)
        let speed = Double.random(in: 180...360)
        let spin = Double.random(in: -8...8)
        let size = CGSize(width: Double.random(in: 4...8), height: Double.random(in: 6...11))
        let hue = Int.random(in: 0..<5)
    }

    private static let colors: [Color] = [Theme.accent, .yellow, .pink, .teal, .purple]

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { timeline in
            Canvas { context, size in
                guard let start else { return }
                let t = timeline.date.timeIntervalSince(start)
                guard t < duration else { return }
                let origin = CGPoint(x: size.width / 2, y: size.height * 0.35)
                let fade = max(0, 1 - t / duration)
                for piece in pieces {
                    let x = origin.x + cos(piece.angle) * piece.speed * t
                    let y = origin.y + sin(piece.angle) * piece.speed * t + 420 * t * t
                    var copy = context
                    copy.opacity = fade
                    copy.translateBy(x: x, y: y)
                    copy.rotate(by: .radians(piece.spin * t))
                    let rect = CGRect(origin: CGPoint(x: -piece.size.width / 2, y: -piece.size.height / 2), size: piece.size)
                    copy.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(Self.colors[piece.hue]))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // The burst is shown when a batch finishes: either it appears then, or the trigger changes.
        .onAppear(perform: burst)
        .onChange(of: trigger) { _, _ in burst() }
    }

    private func burst() {
        let now = Date()
        start = now
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            if start == now { start = nil }
        }
    }
}
