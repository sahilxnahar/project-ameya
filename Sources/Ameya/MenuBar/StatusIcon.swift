import AppKit

/// Ameya's menu bar glyph, drawn as a template image so it matches the menu bar in light, dark,
/// tinted and high-contrast appearances: a tangerine (round fruit, stem and leaf).
///
/// - Idle: the fruit's outline.
/// - Working: the outline becomes a progress ring, filling clockwise from the stem.
/// - Just finished: the fruit is drawn filled for a moment (a static picture, so Reduce Motion
///   needs nothing special).
/// - Hovered by a file drag: filled, with a "+" cut out.
enum StatusIcon {
    enum Look: Equatable {
        case idle
        case working(Double)
        case finished
        case dropTarget
    }

    static let size = NSSize(width: 18, height: 18)

    static func image(_ look: Look) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(look)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(_ look: Look) {
        NSColor.black.setStroke()
        NSColor.black.setFill()
        let center = NSPoint(x: 9, y: 7.75)
        let radius: CGFloat = 6.25
        let fruit = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                width: radius * 2, height: radius * 2))
        fruit.lineWidth = 1.5

        switch look {
        case .idle:
            fruit.stroke()
        case .working(let fraction):
            // A faint full ring, with the done part solid on top.
            NSGraphicsContext.current?.saveGraphicsState()
            NSColor.black.withAlphaComponent(0.3).setStroke()
            fruit.stroke()
            NSGraphicsContext.current?.restoreGraphicsState()
            let clamped = min(max(fraction, 0.04), 1)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                          endAngle: 90 - 360 * clamped, clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            arc.stroke()
        case .finished:
            fruit.fill()
        case .dropTarget:
            fruit.fill()
            // Cut a "+" out of the fruit so the drop target reads clearly.
            NSGraphicsContext.current?.compositingOperation = .clear
            let plus = NSBezierPath()
            plus.move(to: NSPoint(x: center.x - 3, y: center.y))
            plus.line(to: NSPoint(x: center.x + 3, y: center.y))
            plus.move(to: NSPoint(x: center.x, y: center.y - 3))
            plus.line(to: NSPoint(x: center.x, y: center.y + 3))
            plus.lineWidth = 1.75
            plus.lineCapStyle = .round
            plus.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }

        // Stem and leaf, always solid.
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: center.x, y: center.y + radius - 0.5))
        stem.line(to: NSPoint(x: center.x - 0.6, y: center.y + radius + 2.6))
        stem.lineWidth = 1.4
        stem.lineCapStyle = .round
        stem.stroke()
        let leaf = NSBezierPath()
        leaf.move(to: NSPoint(x: center.x - 0.2, y: center.y + radius + 1.6))
        leaf.curve(to: NSPoint(x: center.x + 4.6, y: center.y + radius + 2.4),
                   controlPoint1: NSPoint(x: center.x + 1.2, y: center.y + radius + 3.9),
                   controlPoint2: NSPoint(x: center.x + 3.4, y: center.y + radius + 3.8))
        leaf.curve(to: NSPoint(x: center.x - 0.2, y: center.y + radius + 1.6),
                   controlPoint1: NSPoint(x: center.x + 3.4, y: center.y + radius + 0.9),
                   controlPoint2: NSPoint(x: center.x + 1.2, y: center.y + radius + 0.7))
        leaf.fill()
    }
}
