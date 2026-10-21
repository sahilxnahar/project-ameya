import AmeyaCore
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The logo chosen in "Watermark…", copied as a PNG into the app's temporary folder so every
/// job can send it to the worker as its second input.
@MainActor
enum WatermarkLogo {
    static var url: URL?

    static func choose() -> (URL, CGImage)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a logo picture. A PNG with a see-through background works best."
        guard panel.runModal() == .OK, let picked = panel.url,
              let image = PhotoPreview.load(picked, longSide: 2048) else { return nil }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("ameya-logo-\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(copy as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        url = copy
        return (copy, image)
    }
}

// MARK: Watermark

struct ImageWatermarkPanel: View {
    let done: (ConversionOptions) -> Void

    @EnvironmentObject private var store: JobStore
    @State private var original: CGImage?
    @State private var rendered: CGImage?
    @State private var mark = Watermark(text: "© ", opacity: 0.7, size: 0.3)
    @State private var logo: CGImage?
    @State private var logoName: String?

    private var ready: Bool { mark.useLogo ? logo != nil : !mark.text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            PhotoStage(image: rendered ?? original, height: 340, label: "Preview with the watermark")
                .frame(minWidth: 340)
            VStack(alignment: .leading, spacing: 10) {
                Picker("Mark", selection: $mark.useLogo) {
                    Text("Text").tag(false)
                    Text("Logo").tag(true)
                }
                .pickerStyle(.segmented)
                if mark.useLogo {
                    HStack {
                        Button(logo == nil ? "Choose Logo…" : "Change Logo…") {
                            if let (url, image) = WatermarkLogo.choose() { logo = image; logoName = url.lastPathComponent }
                        }
                        if logoName != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Logo chosen") }
                    }
                } else {
                    TextField("Watermark text", text: $mark.text, prompt: Text("© Your name"))
                        .textFieldStyle(.roundedBorder)
                }
                Text("Position").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                    ForEach(0..<3) { row in
                        GridRow {
                            ForEach(0..<3) { column in
                                spot(Watermark.Position.allCases[row * 3 + column])
                            }
                        }
                    }
                }
                AdjustmentSlider(title: "Opacity", value: $mark.opacity, range: 0.05...1)
                AdjustmentSlider(title: "Size", value: $mark.size, range: 0.05...0.9, step: 0.02)
                if store.pending.count > 1 {
                    Text("Applies to all \(store.pending.count) pictures.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HStack {
                    Spacer()
                    Button("Add Watermark") { done(ConversionOptions(image: .photo(watermark: mark))) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!ready)
                }
            }
            .frame(width: 260)
        }
        .frame(minWidth: 640)
        .onAppear { if original == nil { original = PhotoPreview.load(store.pending.first?.url, longSide: 1000) } }
        .task(id: PreviewKey(mark: mark, hasLogo: logo != nil)) {
            guard let original else { return }
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            rendered = ready ? await PhotoPreview.render(.photo(watermark: mark), on: original, logo: logo) : nil
        }
    }

    private struct PreviewKey: Equatable {
        let mark: Watermark
        let hasLogo: Bool
    }

    private func spot(_ position: Watermark.Position) -> some View {
        let chosen = mark.position == position
        return Button { mark.position = position } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(chosen ? Theme.accent : Color.secondary.opacity(0.2))
                .frame(width: 30, height: 22)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(position.displayName)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .help(position.displayName)
    }
}

// MARK: Annotate

/// "Annotate…": arrows, boxes, text, numbered steps and a highlighter, with undo (⌘Z).
struct AnnotatePanel: View {
    let done: (ConversionOptions) -> Void

    @EnvironmentObject private var store: JobStore
    @State private var original: CGImage?
    @State private var rendered: CGImage?
    @State private var marks: [Annotation] = []
    @State private var undone: [Annotation] = []
    @State private var kind = Annotation.Kind.arrow
    @State private var colour = Annotation.Colour.red
    @State private var text = "Look here"
    @State private var dragging: Annotation?

    private var nextStep: Int { (marks.filter { $0.kind == .step }.compactMap(\.number).max() ?? 0) + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Tool", selection: $kind) {
                    Label("Arrow", systemImage: "arrow.up.right").tag(Annotation.Kind.arrow)
                    Label("Box", systemImage: "rectangle").tag(Annotation.Kind.rectangle)
                    Label("Text", systemImage: "textformat").tag(Annotation.Kind.text)
                    Label("Step", systemImage: "1.circle").tag(Annotation.Kind.step)
                    Label("Highlight", systemImage: "highlighter").tag(Annotation.Kind.highlight)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker("Colour", selection: $colour) {
                    ForEach(Annotation.Colour.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .fixedSize()
            }
            if kind == .text {
                TextField("Text to place", text: $text).textFieldStyle(.roundedBorder)
            }
            PhotoStage(image: rendered ?? original, height: 360, label: "Photo with \(marks.count) marks") { size in
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        dragging = mark(from: value.startLocation, to: value.location, in: size)
                    }.onEnded { value in
                        dragging = nil
                        add(mark(from: value.startLocation, to: value.location, in: size))
                    })
                    .accessibilityLabel("Drawing area")
                    .accessibilityHint("Drag to draw. Text and steps go where you click.")
            }
            Text(hint).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Undo") { if let last = marks.popLast() { undone.append(last) } }
                    .keyboardShortcut("z")
                    .disabled(marks.isEmpty)
                Button("Redo") { if let last = undone.popLast() { marks.append(last) } }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(undone.isEmpty)
                Spacer()
                Button("Save Copy") { done(ConversionOptions(image: .photo(annotations: marks))) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(marks.isEmpty)
            }
        }
        .frame(width: 640)
        .onAppear { if original == nil { original = PhotoPreview.load(store.pending.first?.url, longSide: 1400) } }
        .task(id: marks + (dragging.map { [$0] } ?? [])) {
            guard let original else { return }
            let all = marks + (dragging.map { [$0] } ?? [])
            rendered = all.isEmpty ? nil : await PhotoPreview.render(.photo(annotations: all), on: original)
        }
    }

    private var hint: String {
        switch kind {
        case .arrow: "Drag from where the arrow starts to what it points at."
        case .rectangle: "Drag to draw a box."
        case .text: "Click where the text should go."
        case .step: "Click to place step \(nextStep)."
        case .highlight: "Drag across what to highlight."
        }
    }

    private func mark(from a: CGPoint, to b: CGPoint, in size: CGSize) -> Annotation {
        func unit(_ p: CGPoint) -> PhotoPoint {
            PhotoPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1))
        }
        let tapped = kind == .text || kind == .step
        return Annotation(kind: kind, start: unit(tapped ? b : a), end: unit(b), text: kind == .text ? text : nil,
                          number: kind == .step ? nextStep : nil, colour: colour)
    }

    private func add(_ annotation: Annotation) {
        let length = hypot(annotation.end.x - annotation.start.x, annotation.end.y - annotation.start.y)
        guard annotation.kind == .text || annotation.kind == .step || length > 0.01 else { return }
        if annotation.kind == .text, (annotation.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return }
        marks.append(annotation)
        undone = []
    }
}
