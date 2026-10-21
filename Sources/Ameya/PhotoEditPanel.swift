import AmeyaCore
import SwiftUI

/// "Edit photo…": light and colour sliders with a live preview. Hold the preview (or press M)
/// to compare with the original. Double-click a slider to reset it.
struct PhotoEditPanel: View {
    let done: (ConversionOptions) -> Void

    @EnvironmentObject private var store: JobStore
    @State private var original: CGImage?
    @State private var rendered: CGImage?
    @State private var showOriginal = false
    @State private var holding = false
    @State private var a = Settings()

    struct Settings: Equatable {
        var exposure = 0.0, contrast = 0.0, saturation = 0.0, warmth = 0.0, tint = 0.0
        var highlights = 0.0, shadows = 0.0, sharpness = 0.0, vignette = 0.0
        var autoEnhance = false

        var adjustments: PhotoAdjustments {
            func value(_ x: Double) -> Double? { abs(x) < 0.005 ? nil : x }
            return PhotoAdjustments(exposure: value(exposure), contrast: value(contrast), saturation: value(saturation),
                                    warmth: value(warmth), tint: value(tint), highlights: value(highlights),
                                    shadows: value(shadows), sharpness: value(sharpness), vignette: value(vignette),
                                    autoEnhance: autoEnhance ? true : nil)
        }
    }

    private var comparing: Bool { showOriginal || holding }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 6) {
                PhotoStage(image: comparing ? original : (rendered ?? original), height: 360,
                           label: comparing ? "Original photo" : "Preview of the edited photo")
                    .onLongPressGesture(minimumDuration: 0.1, maximumDistance: 50) {} onPressingChanged: { holding = $0 }
                    .accessibilityHint("Hold to see the original.")
                Text(comparing ? "Original" : "Hold the picture or press M to compare")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minWidth: 340)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Auto enhance", isOn: $a.autoEnhance)
                    .accessibilityHint("Lets the Mac fix exposure, colour and contrast for you. The sliders still apply on top.")
                Group {
                    section("Light")
                    AdjustmentSlider(title: "Exposure", value: $a.exposure)
                    AdjustmentSlider(title: "Contrast", value: $a.contrast)
                    AdjustmentSlider(title: "Highlights", value: $a.highlights)
                    AdjustmentSlider(title: "Shadows", value: $a.shadows)
                    section("Colour")
                    AdjustmentSlider(title: "Saturation", value: $a.saturation)
                    AdjustmentSlider(title: "Warmth", value: $a.warmth)
                    AdjustmentSlider(title: "Tint", value: $a.tint)
                    section("Detail")
                    AdjustmentSlider(title: "Sharpness", value: $a.sharpness, range: 0...1)
                    AdjustmentSlider(title: "Vignette", value: $a.vignette, range: 0...1)
                }
                Spacer(minLength: 8)
                LocalOnlyNote()
                HStack {
                    Button("Reset") { a = Settings() }
                        .disabled(a == Settings())
                        .accessibilityHint("Puts every slider back to unchanged.")
                    Button(showOriginal ? "Show Edit" : "Show Original") { showOriginal.toggle() }
                        .keyboardShortcut("m", modifiers: [])
                        .accessibilityHint("Switches the preview between the original and your edit.")
                    Spacer()
                    Button("Save Copy") { done(ConversionOptions(image: .photo(adjustments: a.adjustments))) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(a.adjustments.isNeutral)
                        .accessibilityHint("Saves an edited copy next to the original.")
                }
            }
            .frame(width: 300)
        }
        .frame(minWidth: 680)
        .onAppear { if original == nil { original = PhotoPreview.load(store.pending.first?.url) } }
        .task(id: a) {
            guard let original else { return }
            try? await Task.sleep(for: .milliseconds(40)) // let a dragged slider settle
            guard !Task.isCancelled else { return }
            rendered = await PhotoPreview.render(.photo(adjustments: a.adjustments), on: original)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}
