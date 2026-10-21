import Foundation

/// What the worker tells the app about a PDF, so the app never has to open the PDF itself.
///
/// The worker answers a `PDFAction.preview` request with a TAR stream (`ConversionResult.outputNames`)
/// holding `info.json` (this type) followed by small page images named `page-0001.png`, `page-0002.png`, …
public struct PDFPreviewInfo: Codable, Sendable, Equatable {
    public static let fileName = "info.json"
    /// Most page images one preview carries; longer PDFs get images for their first pages only.
    public static let maxThumbnails = 500
    /// Longest side, in pixels, of a page image.
    public static let defaultThumbnailSide = 220
    /// The side is always held inside this range, whatever a request asks for.
    public static let thumbnailSideRange = 16...512
    /// The most pages a preview describes. Beyond this the worker refuses the file.
    public static let maxPages = 10_000
    /// The most bytes the app accepts for one page image or for `info.json`.
    public static let maxFileBytes = 1 << 20

    public struct Page: Codable, Sendable, Equatable {
        /// Upright size (after rotation), in points.
        public var width: Double
        public var height: Double
        /// The page's own rotation: 0, 90, 180 or 270.
        public var rotation: Int

        public init(width: Double, height: Double, rotation: Int) {
            self.width = width
            self.height = height
            self.rotation = rotation
        }
    }

    public var pageCount: Int
    /// Still locked after the password (if any) was tried; then there are no pages or images.
    public var locked: Bool
    /// One entry per page, in order.
    public var pages: [Page]
    /// How many page images follow (pages 1…thumbnailCount).
    public var thumbnailCount: Int

    public init(pageCount: Int, locked: Bool, pages: [Page], thumbnailCount: Int) {
        self.pageCount = pageCount
        self.locked = locked
        self.pages = pages
        self.thumbnailCount = thumbnailCount
    }

    /// Whether some pages have no image because the PDF is longer than the preview limit.
    public var isTruncated: Bool { thumbnailCount < pageCount && thumbnailCount > 0 }

    /// File name of the image for `page` (1-based).
    public static func thumbnailName(_ page: Int) -> String {
        let digits = String(page)
        return "page-" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits + ".png"
    }

    /// Checks what came from the worker: sizes in range and counts that agree.
    public var isConsistent: Bool {
        pageCount >= 0 && pageCount <= Self.maxPages && pages.count == (locked ? 0 : pageCount)
            && (0...min(pageCount, Self.maxThumbnails)).contains(thumbnailCount)
            && pages.allSatisfy { $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }
    }
}
