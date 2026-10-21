import AmeyaCore
import SwiftUI

// MARK: Remove background

/// "Remove background": lift the subject (on this Mac), all subjects or the largest, optionally
/// as a sticker, saved as PNG, HEIC or WebP with transparency.
struct RemoveBackgroundPanel: View {
    let done: (ConversionOptions) -> Void
    let writable: Set<FileFormat>

    @EnvironmentObject private var store: JobStore
    @State private var original: CGImage?
    @State private var rendered: CGImage?
    @State private var noSubject = false
    @State private var working = false
    @State private var subjects = BackgroundRemoval.Subjects.all
    @State private var sticker = false
    @State private var format = FileFormat.png

    private var formats: [FileFormat] { [.png, .heic, .webp].filter(writable.contains) }
    private var removal: BackgroundRemoval { BackgroundRemoval(subjects: subjects, sticker: sticker, format: format) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                PhotoStage(image: rendered ?? original, height: 320,
                           label: rendered == nil ? "Original photo" : "Preview without the background")
                if working { ProgressView("Finding the subject…").padding(10).background(.regularMaterial, in: Capsule()) }
            }
            if noSubject {
                PanelProblem(message: "No clear subject was found. Try a photo where a person, pet or object stands out.")
            }
            Picker("Keep", selection: $subjects) {
                Text("Every subject").tag(BackgroundRemoval.Subjects.all)
                Text("Only the largest").tag(BackgroundRemoval.Subjects.largest)
            }
            .pickerStyle(.segmented)
            Toggle("Sticker style (white outline and soft shadow)", isOn: $sticker)
            Picker("Save as", selection: $format) {
                ForEach(formats, id: \.self) { Text($0.displayName).tag($0) }
            }
            .fixedSize()
            .accessibilityHint("All of these keep the see-through background.")
            LocalOnlyNote()
            HStack {
                Spacer()
                Button("Remove Background") { done(ConversionOptions(image: .photo(removeBackground: removal))) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(noSubject)
            }
        }
        .frame(width: 520)
        .onAppear { if original == nil { original = PhotoPreview.load(store.pending.first?.url, longSide: 900) } }
        .task(id: [subjects.rawValue, String(sticker)]) {
            guard let original else { return }
            working = true
            let edits = ImageEdits.photo(removeBackground: removal)
            rendered = await PhotoPreview.render(edits, on: original)
            noSubject = rendered == nil && store.pending.count == 1
            working = false
        }
    }
}

// MARK: Add background / beautify

/// "Add background…": padding, a backdrop, rounded corners, a soft shadow and an optional window frame.
struct BeautifyPanel: View {
    let done: (ConversionOptions) -> Void

    @EnvironmentObject private var store: JobStore
    @State private var original: CGImage?
    @State private var rendered: CGImage?
    @State private var style = Beautify()

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            PhotoStage(image: rendered ?? original, height: 340, label: "Preview with the new background")
                .frame(minWidth: 340)
            VStack(alignment: .leading, spacing: 10) {
                Text("Background").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Beautify.Backdrop.allCases, id: \.self) { backdrop in
                        swatch(backdrop)
                    }
                }
                AdjustmentSlider(title: "Padding", value: $style.padding, range: 0...0.3, step: 0.01)
                AdjustmentSlider(title: "Corners", value: $style.cornerRadius, range: 0...0.1, step: 0.005)
                Toggle("Soft shadow", isOn: $style.shadow)
                Toggle("Window frame", isOn: $style.windowFrame)
                    .accessibilityHint("Adds a plain title bar with three window buttons, like a Mac window.")
                Spacer(minLength: 8)
                HStack {
                    Spacer()
                    Button("Save Copy") { done(ConversionOptions(image: .photo(beautify: style))) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 260)
        }
        .frame(minWidth: 640)
        .onAppear { if original == nil { original = PhotoPreview.load(store.pending.first?.url, longSide: 1000) } }
        .task(id: style) {
            guard let original else { return }
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            rendered = await PhotoPreview.render(.photo(beautify: style), on: original)
        }
    }

    private func swatch(_ backdrop: Beautify.Backdrop) -> some View {
        let chosen = style.backdrop == backdrop
        return Button { style.backdrop = backdrop } label: {
            ZStack {
                if let colours = backdrop.colours {
                    LinearGradient(colors: [Color(colours.start), Color(colours.end)], startPoint: .topLeading, endPoint: .bottomTrailing)
                } else {
                    Checkerboard()
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(chosen ? Theme.accent : .secondary.opacity(0.3), lineWidth: chosen ? 3 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(backdrop.displayName)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .help(backdrop.displayName)
    }
}

extension Color {
    init(_ rgb: RGB) { self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue) }
}
