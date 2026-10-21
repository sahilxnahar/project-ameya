import Foundation

/// The layout of the drag wheel: `count` equal wedges in a ring around the pointer.
///
/// Coordinates are relative to the wheel's centre with y pointing **up** (AppKit screen space).
/// Angles are measured clockwise from 12 o'clock, in radians, in `0..<2π`. Wedge 0 is centred
/// at the top and the rest follow clockwise, the way people read a clock.
public struct WheelGeometry: Sendable, Equatable {
    public let count: Int
    /// The empty middle. Dropping there cancels, so the pointer starts in a safe spot.
    public let innerRadius: Double
    public let outerRadius: Double
    /// How far past the outer edge a drop still counts for the nearest wedge (forgiving aim).
    public let slack: Double

    public init(count: Int, innerRadius: Double, outerRadius: Double, slack: Double = 24) {
        precondition(innerRadius >= 0 && outerRadius > innerRadius, "Invalid wheel radii")
        self.count = max(0, count)
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.slack = max(0, slack)
    }

    /// The width of one wedge, in radians.
    public var span: Double { count > 0 ? 2 * .pi / Double(count) : 0 }

    /// The clockwise-from-top angle of a point, in `0..<2π`.
    public static func angle(dx: Double, dy: Double) -> Double {
        let raw = atan2(dx, dy) // clockwise from +y
        return raw < 0 ? raw + 2 * .pi : raw
    }

    /// The wedge whose angular range contains `angle`, ignoring distance.
    public func wedge(atAngle angle: Double) -> Int? {
        guard count > 0 else { return nil }
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        // Shift by half a wedge so wedge 0 straddles 12 o'clock.
        let index = Int(((a + span / 2) / span).rounded(.down)) % count
        return index
    }

    /// The wedge under a point, or `nil` in the dead middle or well outside the ring.
    public func wedge(dx: Double, dy: Double) -> Int? {
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance >= innerRadius, distance <= outerRadius + slack else { return nil }
        return wedge(atAngle: Self.angle(dx: dx, dy: dy))
    }

    /// The angle at the middle of a wedge.
    public func centerAngle(of index: Int) -> Double {
        Double(index) * span
    }

    /// Start and end angles of a wedge (end may exceed 2π for the wedge straddling the top).
    public func angles(of index: Int) -> (start: Double, end: Double) {
        let middle = centerAngle(of: index)
        var start = middle - span / 2
        if start < 0 { start += 2 * .pi }
        return (start, start + span)
    }

    /// Where a wedge's icon and label sit: halfway through the ring, at the wedge's middle angle.
    /// Returned in the same y-up space as the input points.
    public func labelCenter(of index: Int) -> (x: Double, y: Double) {
        let radius = (innerRadius + outerRadius) / 2
        let angle = centerAngle(of: index)
        return (sin(angle) * radius, cos(angle) * radius)
    }

    /// The largest label width that fits inside a wedge without crossing into its neighbours,
    /// measured as the chord at the label radius, less padding.
    public var maxLabelWidth: Double {
        guard count > 1 else { return outerRadius - innerRadius }
        let radius = (innerRadius + outerRadius) / 2
        let chord = 2 * radius * sin(span / 2)
        return max(24, min(chord, outerRadius - innerRadius + 24) - 10)
    }
}

/// Wheel sizes offered in Settings.
public enum WheelSize: String, CaseIterable, Sendable, Codable {
    case small, medium, large

    public var outerRadius: Double {
        switch self {
        case .small: 112
        case .medium: 140
        case .large: 172
        }
    }

    public var innerRadius: Double { outerRadius * 0.36 }

    public var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    public func geometry(count: Int) -> WheelGeometry {
        WheelGeometry(count: count, innerRadius: innerRadius, outerRadius: outerRadius)
    }
}
