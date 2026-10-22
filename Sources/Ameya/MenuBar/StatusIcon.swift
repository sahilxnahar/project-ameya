import AppKit

/// Ameya's menu bar icon, drawn as a template image (black + alpha) so it follows the menu bar in
/// light, dark, tinted and high-contrast appearances.
///
/// The Ameya mark (Resources/Brand/ameya-mark.svg) is a woven eight-point star. At 18 points its
/// knot turns to mush, so the menu bar uses a reduced version of the same star: a square and a
/// diamond interlaced, around a small diamond at the centre.
///
/// - Idle: the star's outline.
/// - Working (style "with progress"): the diamond is traced solid from the top, clockwise, as
///   the jobs progress; the rest stays faint.
/// - Just finished: the centre fills for a moment (a static picture, so Reduce Motion needs nothing).
/// - Hovered by a file drag: the whole star fills, with a "+" cut out.
enum StatusIcon {
    enum Look: Equatable {
        case idle
        case working(Double)
        case finished
        case dropTarget
    }

    /// Settings → Menu → "Menu bar icon".
    enum Style: String, CaseIterable, Identifiable {
        /// The reduced mark, showing progress while files convert (the default).
        case progress
        /// The reduced mark, never changing while files convert.
        case simple
        /// The full Ameya mark (detailed; best on high-resolution screens).
        case logo

        var id: String { rawValue }

        var title: String {
            switch self {
            case .progress: "Ameya mark with progress"
            case .simple: "Ameya mark, still"
            case .logo: "Full Ameya logo"
            }
        }
    }

    static let size = NSSize(width: 18, height: 18)

    static func image(_ look: Look, style: Style = .progress) -> NSImage {
        if style == .logo, look == .idle || look == .finished || isWorking(look), let logo = fullLogo {
            return logo
        }
        let shown: Look = style == .simple && isWorking(look) ? .idle : look
        let image = NSImage(size: size, flipped: false) { _ in
            draw(shown)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Ameya"
        return image
    }

    private static func isWorking(_ look: Look) -> Bool {
        if case .working = look { return true }
        return false
    }

    /// The full mark, rendered by scripts/render-brand.sh into the app's Resources (1x and 2x).
    private static let fullLogo: NSImage? = {
        guard let image = Bundle.main.image(forResource: "MenuBarLogo") else { return nil }
        image.size = size
        image.isTemplate = true
        image.accessibilityDescription = "Ameya"
        return image
    }()

    // MARK: Drawing (18 × 18 points, origin bottom left)

    private static let center = NSPoint(x: 9, y: 9)

    /// The diamond (a square on its point), traced from the top, clockwise.
    private static func diamond(_ radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x, y: center.y + radius))
        path.line(to: NSPoint(x: center.x + radius, y: center.y))
        path.line(to: NSPoint(x: center.x, y: center.y - radius))
        path.line(to: NSPoint(x: center.x - radius, y: center.y))
        path.close()
        path.lineJoinStyle = .round
        return path
    }

    private static func square(_ half: CGFloat) -> NSBezierPath {
        let path = NSBezierPath(rect: NSRect(x: center.x - half, y: center.y - half, width: half * 2, height: half * 2))
        path.lineJoinStyle = .round
        return path
    }

    private static func draw(_ look: Look) {
        NSColor.black.setStroke()
        NSColor.black.setFill()
        let outerDiamond = diamond(8.1)
        let outerSquare = square(5.6)
        let inner = diamond(2.6)
        for path in [outerDiamond, outerSquare] { path.lineWidth = 1.15 }
        inner.lineWidth = 1.1

        switch look {
        case .idle:
            outerSquare.stroke()
            outerDiamond.stroke()
            inner.stroke()
        case .working(let fraction):
            outerSquare.stroke()
            inner.stroke()
            NSGraphicsContext.current?.saveGraphicsState()
            NSColor.black.withAlphaComponent(0.28).setStroke()
            outerDiamond.stroke()
            NSGraphicsContext.current?.restoreGraphicsState()
            // The done part of the diamond, solid, starting at the top.
            let perimeter = 4 * (8.1 * 2.squareRoot())
            let done = perimeter * min(max(fraction, 0.04), 1)
            let progress = diamond(8.1)
            progress.lineWidth = 1.7
            progress.lineCapStyle = .round
            progress.setLineDash([done, perimeter], count: 2, phase: 0)
            progress.stroke()
        case .finished:
            outerSquare.stroke()
            outerDiamond.stroke()
            inner.fill()
            inner.stroke()
        case .dropTarget:
            outerSquare.fill()
            outerDiamond.fill()
            // Cut a "+" out so the drop target reads clearly.
            NSGraphicsContext.current?.compositingOperation = .clear
            let plus = NSBezierPath()
            plus.move(to: NSPoint(x: center.x - 3.2, y: center.y))
            plus.line(to: NSPoint(x: center.x + 3.2, y: center.y))
            plus.move(to: NSPoint(x: center.x, y: center.y - 3.2))
            plus.line(to: NSPoint(x: center.x, y: center.y + 3.2))
            plus.lineWidth = 1.8
            plus.lineCapStyle = .round
            plus.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }
    }
}
