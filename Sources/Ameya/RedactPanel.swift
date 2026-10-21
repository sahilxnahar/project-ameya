import AmeyaCore
import SwiftUI

/// "Redact…": drag boxes over what should be hidden, or let the Mac find faces, text and
/// number plates. Keyboard: Tab picks the next box, arrow keys move it, ⇧ + arrow keys resize it,
/// Delete removes it. The cover is burnt into the pixels and hidden details are removed.
struct RedactPanel: View {
    let done: (ConversionOptions) -> Void

    @EnvironmentObject private var store: JobStore
    @State private var original: CGImage?
    @State private var rendered: CGImage?
    @State private var boxes: [UnitRect] = []
    @State private var selected: Int?
    @State private var style = Redaction.Style.pixelate
    @State private var drawing: UnitRect?
    @State private var finding: String?
    @State private var message: String?
    @FocusState private var canvasFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhotoStage(image: rendered ?? original, height: 380, label: "Photo with \(boxes.count) hidden areas") { size in
                canvas(size)
            }
            HStack(spacing: 8) {
                finder("Find Faces", "person.crop.square") { PhotoVision.faces(in: $0) }
                finder("Find Text", "text.viewfinder") { PhotoVision.text(in: $0) }
                finder("Find Number Plates", "car") { PhotoVision.numberPlates(in: $0) }
                if let finding { ProgressView().controlSize(.small).accessibilityLabel(finding) }
                Spacer()
                Picker("Cover", selection: $style) {
                    ForEach(Redaction.Style.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .fixedSize()
            }
            Text(message ?? "Drag over anything to hide. Tab picks a box, arrows move it, ⇧ arrows resize, Delete removes.")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            Label("The cover can't be undone in the copy, and location, camera details and thumbnails are removed too.",
                  systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Remove All") { boxes = []; selected = nil }
                    .disabled(boxes.isEmpty)
                Spacer()
                Button("Save Redacted Copy") {
                    done(ConversionOptions(image: .photo(redaction: Redaction(boxes: boxes, style: style), metadata: .removeAll)))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(boxes.isEmpty)
                .accessibilityHint("Saves a copy with the areas covered for good.")
            }
        }
        .frame(width: 620)
        .onAppear {
            if original == nil { original = PhotoPreview.load(store.pending.first?.url, longSide: 1800) }
            canvasFocused = true
        }
        .task(id: RenderKey(boxes: boxes, style: style)) {
            guard let original else { return }
            rendered = boxes.isEmpty ? nil : await PhotoPreview.render(.photo(redaction: Redaction(boxes: boxes, style: style)), on: original)
        }
    }

    private struct RenderKey: Equatable {
        let boxes: [UnitRect]
        let style: Redaction.Style
    }

    // MARK: Canvas

    private func canvas(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
            ForEach(Array(boxes.enumerated()), id: \.offset) { index, box in
                outline(box, in: size, selected: index == selected)
            }
            if let drawing { outline(drawing, in: size, selected: true) }
        }
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            drawing = rect(from: value.startLocation, to: value.location, in: size)
        }.onEnded { value in
            defer { drawing = nil }
            let box = rect(from: value.startLocation, to: value.location, in: size)
            if box.width * size.width < 4 || box.height * size.height < 4 { // a click: pick the box under it
                let point = CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)
                selected = boxes.lastIndex { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(point) }
            } else {
                boxes.append(box)
                selected = boxes.count - 1
            }
            canvasFocused = true
        })
        .focusable()
        .focused($canvasFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
            nudge(press) ? .handled : .ignored
        }
        .onKeyPress(.tab) {
            guard !boxes.isEmpty else { return .ignored }
            selected = ((selected ?? -1) + 1) % boxes.count
            announce()
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard let index = selected, boxes.indices.contains(index) else { return .ignored }
            boxes.remove(at: index)
            selected = boxes.isEmpty ? nil : min(index, boxes.count - 1)
            message = "Box removed. \(boxes.count) left."
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel("Areas to hide")
        .accessibilityValue(boxes.isEmpty ? "None yet" : "\(boxes.count) areas" + (selected.map { ", area \($0 + 1) selected" } ?? ""))
        .accessibilityHint("Tab picks an area, arrow keys move it, Shift and arrow keys resize it, Delete removes it.")
        .accessibilityAction(named: "Next area") { if !boxes.isEmpty { selected = ((selected ?? -1) + 1) % boxes.count } }
        .accessibilityAction(named: "Remove selected area") {
            if let index = selected, boxes.indices.contains(index) { boxes.remove(at: index); selected = nil }
        }
    }

    private func outline(_ box: UnitRect, in size: CGSize, selected: Bool) -> some View {
        Rectangle()
            .strokeBorder(selected ? Theme.accent : .white, style: StrokeStyle(lineWidth: selected ? 2.5 : 1.5, dash: selected ? [] : [5, 3]))
            .shadow(color: .black.opacity(0.6), radius: 1)
            .frame(width: box.width * size.width, height: box.height * size.height)
            .offset(x: box.x * size.width, y: box.y * size.height)
            .allowsHitTesting(false)
    }

    private func rect(from a: CGPoint, to b: CGPoint, in size: CGSize) -> UnitRect {
        UnitRect(x: min(a.x, b.x) / size.width, y: min(a.y, b.y) / size.height,
                 width: abs(a.x - b.x) / size.width, height: abs(a.y - b.y) / size.height).clampedToUnit
    }

    /// Arrow keys move the selected box by 1 % of the picture; with ⇧ they resize it.
    private func nudge(_ press: KeyPress) -> Bool {
        guard let index = selected, boxes.indices.contains(index) else { return false }
        let step = 0.01
        var box = boxes[index]
        let (dx, dy): (Double, Double) = switch press.key {
        case .leftArrow: (-step, 0)
        case .rightArrow: (step, 0)
        case .upArrow: (0, -step)
        default: (0, step)
        }
        if press.modifiers.contains(.shift) {
            box.width = max(0.01, box.width + dx)
            box.height = max(0.01, box.height + dy)
        } else {
            box.x = min(max(0, box.x + dx), 1 - box.width)
            box.y = min(max(0, box.y + dy), 1 - box.height)
        }
        boxes[index] = box.clampedToUnit
        return true
    }

    private func announce() {
        guard let index = selected else { return }
        message = "Area \(index + 1) of \(boxes.count) selected."
    }

    // MARK: Finders

    private func finder(_ title: String, _ symbol: String, _ find: @escaping @Sendable (CGImage) -> [UnitRect]) -> some View {
        Button {
            guard let original else { return }
            finding = "Looking…"
            Task {
                let found = await PhotoPreview.detached(original, find)
                let new = found.filter { candidate in !boxes.contains { overlaps($0, candidate) } }
                boxes += new
                finding = nil
                message = new.isEmpty ? "Nothing new was found. You can still drag boxes yourself."
                    : "Added \(new.count) area\(new.count == 1 ? "" : "s"). Check that nothing was missed."
                if !new.isEmpty { selected = boxes.count - 1 }
            }
        } label: {
            Label(title, systemImage: symbol)
        }
        .disabled(original == nil || finding != nil)
        .help("Looks for them on this Mac and adds a box over each one.")
    }

    private func overlaps(_ a: UnitRect, _ b: UnitRect) -> Bool {
        let first = CGRect(x: a.x, y: a.y, width: a.width, height: a.height)
        let second = CGRect(x: b.x, y: b.y, width: b.width, height: b.height)
        let shared = first.intersection(second)
        return !shared.isNull && shared.width * shared.height > 0.6 * min(first.width * first.height, second.width * second.height)
    }
}
