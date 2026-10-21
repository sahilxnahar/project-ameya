import Foundation

/// Pure geometry for passport photos: where to crop, how far to scale, how many fit on a sheet.
/// Coordinates are pixels with the origin at the top left, y growing downwards.
public enum PassportGeometry {
    /// Share of the head (chin to crown) that lies between the eye line and the chin.
    /// Adult heads have the eyes close to half way; slightly less than half lies below them.
    public static let eyeToChinShareOfHead = 0.48
    /// Without an eye-line rule, this share of the free height goes above the head (the rest below).
    public static let topShareOfFreeHeight = 0.42

    public static func pixels(mm: Double, dpi: Double) -> Int {
        Int((mm / 25.4 * dpi).rounded())
    }

    /// A face measured in a levelled image (eyes horizontal).
    public struct Face: Equatable, Sendable {
        /// Midpoint between the eyes.
        public var eyeX: Double
        public var eyeY: Double
        /// Vertical distance from the eye line down to the bottom of the chin.
        public var eyeToChin: Double

        public init(eyeX: Double, eyeY: Double, eyeToChin: Double) {
            self.eyeX = eyeX
            self.eyeY = eyeY
            self.eyeToChin = eyeToChin
        }

        /// Estimated chin-to-crown height.
        public var headHeight: Double { eyeToChin / PassportGeometry.eyeToChinShareOfHead }
        public var chinY: Double { eyeY + eyeToChin }
        public var crownY: Double { chinY - headHeight }
    }

    public struct Rect: Equatable, Sendable {
        public var x, y, width, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public func isInside(width outerWidth: Double, height outerHeight: Double, tolerance: Double = 0.5) -> Bool {
            x >= -tolerance && y >= -tolerance && x + width <= outerWidth + tolerance && y + height <= outerHeight + tolerance
        }
    }

    /// Where the output comes from in the source image.
    public struct Placement: Equatable, Sendable {
        /// Output pixels per source pixel.
        public var scale: Double
        /// The part of the (levelled) source that becomes the output; may reach past the edges.
        public var sourceRect: Rect
    }

    /// Crops so the head height lands in the middle of the spec's range and the eye line on its
    /// rule (or, without one, the head sits slightly above centre), centred on the eyes.
    public static func placement(for face: Face, spec: PassportSpec, outputWidth: Int, outputHeight: Int) -> Placement {
        let outW = Double(outputWidth), outH = Double(outputHeight)
        let pixelsPerMM = outH / spec.heightMM
        let targetHead = middle(spec.headHeightMM) * pixelsPerMM
        let scale = targetHead / max(face.headHeight, 1)
        let eyeFromTop: Double
        if let eyeRule = spec.eyeLineFromBottomMM {
            eyeFromTop = outH - middle(eyeRule) * pixelsPerMM
        } else {
            let topMargin = (outH - targetHead) * topShareOfFreeHeight
            eyeFromTop = topMargin + (face.headHeight - face.eyeToChin) * scale
        }
        let width = outW / scale, height = outH / scale
        let rect = Rect(x: face.eyeX - width / 2, y: face.eyeY - eyeFromTop / scale, width: width, height: height)
        return Placement(scale: scale, sourceRect: rect)
    }

    /// Head height and eye line (both in mm on the print) that a placement produces; for checks.
    public static func measured(_ face: Face, _ placement: Placement, spec: PassportSpec, outputHeight: Int)
        -> (headMM: Double, eyeFromBottomMM: Double, crownMarginMM: Double) {
        let mmPerPixel = spec.heightMM / Double(outputHeight)
        let eyeOut = (face.eyeY - placement.sourceRect.y) * placement.scale
        let crownOut = (face.crownY - placement.sourceRect.y) * placement.scale
        return (face.headHeight * placement.scale * mmPerPixel,
                (Double(outputHeight) - eyeOut) * mmPerPixel,
                crownOut * mmPerPixel)
    }

    private static func middle(_ range: ClosedRange<Double>) -> Double { (range.lowerBound + range.upperBound) / 2 }

    // MARK: Print sheet

    /// A 4 × 6 in (10 × 15 cm) sheet.
    public static let sheetShortMM = 101.6
    public static let sheetLongMM = 152.4

    public struct SheetLayout: Equatable, Sendable {
        public var columns: Int
        public var rows: Int
        public var landscape: Bool
        /// Space between photos and around the grid, in mm.
        public var gapMM: Double
        public var count: Int { columns * rows }
        public var sheetWidthMM: Double { landscape ? PassportGeometry.sheetLongMM : PassportGeometry.sheetShortMM }
        public var sheetHeightMM: Double { landscape ? PassportGeometry.sheetShortMM : PassportGeometry.sheetLongMM }
    }

    /// The layout fitting the most copies: portrait or landscape, with a 2 mm gap (easier to cut)
    /// unless edge-to-edge fits more. Ties prefer the gap, then portrait.
    public static func sheetLayout(photoWidthMM: Double, photoHeightMM: Double) -> SheetLayout {
        var best: SheetLayout?
        for gap in [2.0, 0] {
            for landscape in [false, true] {
                let width = landscape ? sheetLongMM : sheetShortMM
                let height = landscape ? sheetShortMM : sheetLongMM
                let layout = SheetLayout(columns: fit(photoWidthMM, in: width, gap: gap),
                                         rows: fit(photoHeightMM, in: height, gap: gap),
                                         landscape: landscape, gapMM: gap)
                if layout.count > (best?.count ?? 0) { best = layout }
            }
        }
        return best ?? SheetLayout(columns: 0, rows: 0, landscape: false, gapMM: 0)
    }

    /// How many items of `size` fit in `length` with `gap` between them and around them.
    static func fit(_ size: Double, in length: Double, gap: Double) -> Int {
        guard size > 0 else { return 0 }
        return max(0, Int(((length - gap) / (size + gap)) + 1e-9))
    }

    /// Photo rectangles on the sheet, in pixels from the top left, the grid centred.
    public static func sheetFrames(_ layout: SheetLayout, photoWidthMM: Double, photoHeightMM: Double, dpi: Double) -> [Rect] {
        let mm = dpi / 25.4
        let gridW = Double(layout.columns) * photoWidthMM + Double(max(layout.columns - 1, 0)) * layout.gapMM
        let gridH = Double(layout.rows) * photoHeightMM + Double(max(layout.rows - 1, 0)) * layout.gapMM
        let left = (layout.sheetWidthMM - gridW) / 2, top = (layout.sheetHeightMM - gridH) / 2
        var frames: [Rect] = []
        for row in 0..<layout.rows {
            for column in 0..<layout.columns {
                let x = left + Double(column) * (photoWidthMM + layout.gapMM)
                let y = top + Double(row) * (photoHeightMM + layout.gapMM)
                frames.append(Rect(x: (x * mm).rounded(), y: (y * mm).rounded(),
                                   width: (photoWidthMM * mm).rounded(), height: (photoHeightMM * mm).rounded()))
            }
        }
        return frames
    }
}
