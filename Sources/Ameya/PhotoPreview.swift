import AmeyaCore
import CoreGraphics
import ImageIO
import SwiftUI

/// A small, upright copy of the first pending photo, for the photo tools' live previews.
/// The preview runs the same `PhotoRender` functions as the worker; the full-size result is
/// always made in the sandboxed worker.
enum PhotoPreview {
    static func load(_ url: URL?, longSide: Int = 1400) -> CGImage? {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), options as CFDictionary)
    }

    /// Renders off the main thread; `nil` when the edits can't be previewed (the worker will say why).
    static func render(_ edits: ImageEdits, on image: CGImage, logo: CGImage? = nil) async -> CGImage? {
        let box = Unchecked((image, logo))
        return await Task.detached(priority: .userInitiated) {
            (try? PhotoRender.apply(edits, to: box.value.0, logo: box.value.1)).map(Unchecked.init)
        }.value?.value
    }

    /// Runs Vision (or other slow work) on a picture off the main thread.
    static func detached<T: Sendable>(_ image: CGImage, _ work: @escaping @Sendable (CGImage) -> T) async -> T {
        let box = Unchecked(image)
        return await Task.detached(priority: .userInitiated) { work(box.value) }.value
    }
}

/// CGImage is immutable and thread-safe; this carries it across a task boundary.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// The picture fitted into the available space, with `overlay` laid exactly over it
/// (the overlay receives the picture's on-screen size).
struct PhotoStage<Overlay: View>: View {
    let image: CGImage?
    var height: CGFloat = 340
    var label = "Preview"
    @ViewBuilder var overlay: (CGSize) -> Overlay

    var body: some View {
        GeometryReader { space in
            if let image {
                let size = fitted(image, in: space.size)
                ZStack {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .accessibilityLabel(label)
                        .accessibilityAddTraits(.isImage)
                    overlay(size).frame(width: size.width, height: size.height)
                }
                .frame(width: space.size.width, height: space.size.height)
            } else {
                ProgressView().frame(width: space.size.width, height: space.size.height)
            }
        }
        .frame(height: height)
        .background { Checkerboard().opacity(0.5) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fitted(_ image: CGImage, in space: CGSize) -> CGSize {
        let scale = min(space.width / CGFloat(image.width), space.height / CGFloat(image.height))
        return CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }
}

extension PhotoStage where Overlay == EmptyView {
    init(image: CGImage?, height: CGFloat = 340, label: String = "Preview") {
        self.init(image: image, height: height, label: label) { _ in EmptyView() }
    }
}

/// The usual grey checks behind transparent pictures.
struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 10
            for row in 0..<Int(size.height / step) + 1 {
                for column in 0..<Int(size.width / step) + 1 where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * step, y: CGFloat(row) * step, width: step, height: step)),
                                 with: .color(.gray.opacity(0.25)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A labelled slider: VoiceOver reads its value in words, and the arrow keys nudge it when focused.
struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -1...1
    var step: Double = 0.05

    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 82, alignment: .leading).accessibilityHidden(true)
            Slider(value: $value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(spoken)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: nudge(step)
                    case .decrement: nudge(-step)
                    @unknown default: break
                    }
                }
                .onKeyPress(.rightArrow) { nudge(step); return .handled }
                .onKeyPress(.leftArrow) { nudge(-step); return .handled }
            Text(display)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .onTapGesture(count: 2) { value = range.contains(0) ? 0 : range.lowerBound }
        .help("Double-click to reset \(title.lowercased()).")
    }

    private var display: String {
        let number = Int((value * 100).rounded())
        return range.lowerBound < 0 && number > 0 ? "+\(number)" : "\(number)"
    }

    private var spoken: String {
        let number = Int((value * 100).rounded())
        if number == 0 { return range.lowerBound < 0 ? "unchanged" : "off" }
        return range.lowerBound < 0 ? (number > 0 ? "plus \(number)" : "minus \(-number)") : "\(number) percent"
    }

    private func nudge(_ delta: Double) { value = min(max(value + delta, range.lowerBound), range.upperBound) }
}

/// A short note that everything stays on this Mac.
struct LocalOnlyNote: View {
    var body: some View {
        Label("Everything happens on this Mac. Your photos are never uploaded.", systemImage: "lock")
            .font(.caption).foregroundStyle(.secondary)
    }
}
