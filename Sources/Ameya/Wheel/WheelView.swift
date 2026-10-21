import AmeyaCore
import SwiftUI

/// What the wheel currently shows. Owned by `WheelController`, drawn by `WheelView`.
@MainActor
final class WheelViewModel: ObservableObject {
    @Published var ring: WheelRing = .convert
    @Published var choices: [WheelChoice] = []
    @Published var hovered: Int?
    @Published var fileCount = 0
    @Published var size: WheelSize = .medium
    @Published var mapping: WheelModifierMapping = .standard
    /// Changes on every opening, so the open animation replays.
    @Published var openCount = 0

    var geometry: WheelGeometry { size.geometry(count: choices.count) }

    /// The panel's side: the ring plus room for the lifted wedge, its shadow and the drop slack.
    var diameter: Double { (size.outerRadius + 28) * 2 }
}

/// The radial menu: wedges around an empty middle that says which wheel this is.
struct WheelView: View {
    @ObservedObject var model: WheelViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isOpen = false

    var body: some View {
        let geometry = model.geometry
        let center = model.diameter / 2
        ZStack {
            ringBackground(geometry)
            ForEach(Array(model.choices.enumerated()), id: \.element.id) { index, choice in
                wedge(index, choice: choice, geometry: geometry, center: center)
            }
            hub(geometry)
        }
        .frame(width: model.diameter, height: model.diameter)
        .scaleEffect(isOpen || reduceMotion ? 1 : 0.55)
        .opacity(isOpen ? 1 : 0)
        .onAppear(perform: open)
        .onChange(of: model.openCount) { _, _ in
            isOpen = false
            open()
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.62),
                   value: model.hovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.ring.announcement(choices: model.choices.count))
    }

    private func open() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.68)) {
            isOpen = true
        }
    }

    // MARK: Parts

    private var surface: AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial)
    }

    private var strokeColor: Color {
        contrast == .increased ? .primary : .primary.opacity(0.14)
    }

    private var strokeWidth: CGFloat { contrast == .increased ? 1.5 : 0.75 }

    private func ringBackground(_ geometry: WheelGeometry) -> some View {
        Circle()
            .fill(surface)
            .overlay(Circle().strokeBorder(strokeColor, lineWidth: strokeWidth))
            .frame(width: geometry.outerRadius * 2, height: geometry.outerRadius * 2)
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            .accessibilityHidden(true)
    }

    private func wedge(_ index: Int, choice: WheelChoice, geometry: WheelGeometry, center: Double) -> some View {
        let isHovered = model.hovered == index
        let angles = geometry.angles(of: index)
        let middle = geometry.centerAngle(of: index)
        let lift = isHovered ? 7.0 : 0
        let label = geometry.labelCenter(of: index)
        let shape = WedgeShape(start: angles.start, end: angles.end,
                               inner: geometry.innerRadius, outer: geometry.outerRadius,
                               gap: geometry.count > 1 ? 1.5 : 0)
        return ZStack {
            shape
                .fill(isHovered ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.0001)))
                .overlay(shape.stroke(strokeColor, lineWidth: strokeWidth))
                .shadow(color: .black.opacity(isHovered ? 0.25 : 0), radius: isHovered ? 8 : 0, y: isHovered ? 3 : 0)
            VStack(spacing: 3) {
                Image(systemName: choice.systemImage)
                    .font(.system(size: model.size == .small ? 15 : 18, weight: .medium))
                    .imageScale(.medium)
                Text(choice.title)
                    .font(.system(size: model.size == .small ? 10 : 11, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isHovered ? Color.white : Color.primary)
            .frame(width: geometry.maxLabelWidth)
            .position(x: center + label.x, y: center - label.y)
        }
        .frame(width: model.diameter, height: model.diameter)
        // Lift the highlighted wedge outward along its own direction.
        .offset(x: sin(middle) * lift, y: -cos(middle) * lift)
        .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(choice.title)
        .accessibilityHint(choice.help)
        .accessibilityAddTraits(isHovered ? [.isButton, .isSelected] : .isButton)
    }

    private func hub(_ geometry: WheelGeometry) -> some View {
        VStack(spacing: 4) {
            Text(model.ring.title)
                .font(.system(size: model.size == .small ? 12 : 13, weight: .bold))
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 5) {
                ForEach(WheelRing.allCases, id: \.self) { ring in
                    if let key = model.mapping.key(for: ring) {
                        Text(key.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(ring == model.ring ? Color.accentColor.opacity(0.85)
                                                                         : Color.primary.opacity(0.08)))
                            .foregroundStyle(ring == model.ring ? Color.white : Color.secondary)
                            .accessibilityLabel("\(key.title): \(ring.title)")
                    }
                }
            }
            .padding(.top, 1)
        }
        .frame(width: geometry.innerRadius * 2 - 10)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if model.choices.isEmpty {
            return model.ring == .convert ? "No format suits all these files" : "Nothing for these files"
        }
        let files = model.fileCount == 1 ? "1 file" : "\(model.fileCount) files"
        return "\(files) · drop on a choice"
    }
}

/// A ring segment between two clockwise-from-top angles.
struct WedgeShape: Shape {
    var start: Double
    var end: Double
    var inner: Double
    var outer: Double
    /// Space left between neighbouring wedges, in points.
    var gap: Double

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        // Clockwise from top in y-down view space is the standard angle minus 90°.
        func viewAngle(_ a: Double) -> Angle { .radians(a - .pi / 2) }
        let outerPad = gap / max(outer, 1) / 2
        let innerPad = gap / max(inner, 1) / 2
        var path = Path()
        path.addArc(center: c, radius: outer, startAngle: viewAngle(start + outerPad),
                    endAngle: viewAngle(end - outerPad), clockwise: false)
        path.addArc(center: c, radius: inner, startAngle: viewAngle(end - innerPad),
                    endAngle: viewAngle(start + innerPad), clockwise: true)
        path.closeSubpath()
        return path
    }
}
