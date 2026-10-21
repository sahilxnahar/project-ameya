import AmeyaCore
import Foundation
import SwiftUI

/// The one-click "make it smaller" family: sizes for email, WhatsApp, Instagram, Discord and upload
/// forms, video trim & mute, PDF compression, and a custom size. Panels live in SizePanels.swift.
extension ToolCatalog {
    static func sizePresetTools(writable: Set<FileFormat>) -> [Tool] {
        photoPresets(writable: writable) + videoPresets() + pdfPresets() + [customSize(writable: writable)]
    }

    /// Photos and pictures (not icons), when this Mac can write JPEG.
    static func arePhotos(_ formats: [FileFormat], writable: Set<FileFormat>) -> Bool {
        writable.contains(.jpeg) && formats.allSatisfy { $0.family == .image && !$0.isIcon }
    }

    /// Videos Ameya can read: FFmpeg-only formats need the bundled helper.
    static func areVideos(_ formats: [FileFormat]) -> Bool {
        formats.allSatisfy { $0.family == .video && (!$0.isFFmpegOnly || FFmpegAvailability.isAvailable) }
    }

    /// Keeps a video's format when Ameya can write it; otherwise MP4 (e.g. 3GP, WMV).
    static func keepVideoFormat(_ format: FileFormat) -> FileFormat {
        switch format {
        case .mp4, .mov, .m4v: format
        case .mkv, .webm, .avi: FFmpegAvailability.isAvailable ? format : .mp4
        default: .mp4
        }
    }

    // MARK: Photos

    static func photoPresets(writable: Set<FileFormat>) -> [Tool] {
        let photos: ([FileFormat]) -> Bool = { arePhotos($0, writable: writable) }
        func jpeg(_ edits: ImageEdits) -> (FileFormat) -> ConversionRequest {
            { format in ConversionRequest(source: format, target: .jpeg, options: ConversionOptions(image: edits)) }
        }
        return [
            Tool(id: "photo.email", title: "Fit for email", systemImage: "envelope",
                 help: "Makes a JPEG copy of each photo under 2 MB, ready to attach to an email.",
                 outputSuffix: "(email)", isAvailable: photos, makeRequest: jpeg(ImageEdits(targetBytes: 2_000_000))),
            Tool(id: "photo.whatsapp", title: "WhatsApp-ready", systemImage: "message",
                 help: "Makes a JPEG copy no wider or taller than 1600 pixels, the size WhatsApp sends.",
                 outputSuffix: "(WhatsApp)", isAvailable: photos, makeRequest: jpeg(ImageEdits(maxPixelSize: 1600))),
            Tool(id: "photo.instagram", title: "Instagram size", systemImage: "camera",
                 help: "Makes a JPEG copy no wider or taller than 1080 pixels, the size Instagram shows.",
                 outputSuffix: "(Instagram)", isAvailable: photos, makeRequest: jpeg(ImageEdits(maxPixelSize: 1080))),
            Tool(id: "image.under200KB", title: "Under 200 KB (forms)", systemImage: "scalemass",
                 help: "Makes a JPEG copy of 200 KB or less, for online forms and upload portals.",
                 outputSuffix: "(under 200 KB)", isAvailable: photos, makeRequest: jpeg(ImageEdits(targetBytes: 200_000))),
            Tool(id: "photo.under50KB", title: "Under 50 KB (signatures)", systemImage: "signature",
                 help: "Makes a JPEG copy of 50 KB or less, for signature and passport-photo uploads.",
                 outputSuffix: "(under 50 KB)", isAvailable: photos,
                 makeRequest: jpeg(ImageEdits(maxPixelSize: 1200, targetBytes: 50_000))),
        ]
    }

    // MARK: Videos

    static func videoPresets() -> [Tool] {
        func mp4(_ edits: VideoEdits) -> (FileFormat) -> ConversionRequest {
            { format in ConversionRequest(source: format, target: .mp4, options: ConversionOptions(video: edits)) }
        }
        func keep(_ edits: VideoEdits) -> (FileFormat) -> ConversionRequest {
            { format in ConversionRequest(source: format, target: keepVideoFormat(format), options: ConversionOptions(video: edits)) }
        }
        return [
            Tool(id: "video.email", title: "Fit for email", systemImage: "envelope",
                 help: "Makes an MP4 copy under 25 MB to attach to an email. Very long videos need trimming first.",
                 outputSuffix: "(email)", isAvailable: areVideos, makeRequest: mp4(VideoEdits(targetBytes: 25_000_000))),
            Tool(id: "video.whatsapp", title: "WhatsApp-ready", systemImage: "message",
                 help: "Makes a 720p MP4 copy under 16 MB, WhatsApp's limit for videos.",
                 outputSuffix: "(WhatsApp)", isAvailable: areVideos,
                 makeRequest: mp4(VideoEdits(maxPixelSize: 1280, targetBytes: 16_000_000))),
            Tool(id: "video.discord", title: "Discord-ready", systemImage: "bubble.left.and.bubble.right",
                 help: "Makes an MP4 copy under 10 MB, Discord's limit without a subscription.",
                 outputSuffix: "(Discord)", isAvailable: areVideos, makeRequest: mp4(VideoEdits(targetBytes: 10_000_000))),
            Tool(id: "video.smaller", title: "Make it smaller (720p)", systemImage: "arrow.down.right.and.arrow.up.left",
                 help: "Makes a copy no bigger than 720p (1280 pixels across), in the same format where possible.",
                 outputSuffix: "(720p)", isAvailable: areVideos, makeRequest: keep(VideoEdits(maxPixelSize: 1280))),
            Tool(id: "video.trim", title: "Trim & mute…", systemImage: "scissors",
                 help: "Choose where the video starts and ends, and whether to keep the sound.",
                 outputSuffix: "(trimmed)", isAvailable: areVideos, makeRequest: keep(VideoEdits()),
                 panel: { _, done in AnyView(TrimMutePanel(done: done)) }),
        ]
    }

    // MARK: PDFs

    static func pdfPresets() -> [Tool] {
        let allPDF: ([FileFormat]) -> Bool = { $0.allSatisfy { $0 == .pdf } }
        func compress(_ targetBytes: Int?) -> (FileFormat) -> ConversionRequest {
            { format in
                ConversionRequest(source: format, target: .pdf,
                                  options: ConversionOptions(pdf: .compress(quality: 0.7, targetBytes: targetBytes)))
            }
        }
        return [
            Tool(id: "pdf.smaller", title: "Make PDF smaller", systemImage: "arrow.down.doc",
                 help: "Saves scanned and photo pages as smaller pictures; text stays sharp and selectable.",
                 outputSuffix: "(smaller)", isAvailable: allPDF, makeRequest: compress(nil)),
            Tool(id: "pdf.under2MB", title: "PDF under 2 MB", systemImage: "scalemass",
                 help: "Makes the PDF 2 MB or less by saving scanned and photo pages as smaller pictures.",
                 outputSuffix: "(under 2 MB)", isAvailable: allPDF, makeRequest: compress(2_000_000)),
        ]
    }

    // MARK: Custom

    /// "Custom size…": any byte target for photos, videos or PDFs, with a format choice.
    /// The panel can only hand back options, so it records the chosen format in `choice`,
    /// which `makeRequest` (called right after the panel closes) reads.
    static func customSize(writable: Set<FileFormat>) -> Tool {
        let choice = CustomSizeChoice()
        return Tool(
            id: "size.custom", title: "Custom size…", systemImage: "slider.horizontal.3",
            help: "Choose the largest file size you need, in KB or MB, and the format.",
            outputSuffix: "(smaller)",
            isAvailable: { formats in SizeKind(formats, writable: writable) != nil },
            makeRequest: { format in
                switch format.family {
                case .video:
                    ConversionRequest(source: format, target: choice.videoTarget ?? keepVideoFormat(format),
                                      options: ConversionOptions(video: VideoEdits(targetBytes: 25_000_000)))
                case .document:
                    ConversionRequest(source: format, target: .pdf,
                                      options: ConversionOptions(pdf: .compress(quality: 0.7, targetBytes: 2_000_000)))
                default:
                    ConversionRequest(source: format, target: choice.imageTarget,
                                      options: ConversionOptions(image: ImageEdits(targetBytes: 500_000)))
                }
            },
            panel: { formats, done in
                guard let kind = SizeKind(formats, writable: writable) else { return AnyView(EmptyView()) }
                return AnyView(CustomSizePanel(kind: kind, writable: writable, choice: choice, done: done))
            }
        )
    }
}

/// Which kind of files the custom size applies to: all photos, all videos or all PDFs.
enum SizeKind {
    case photo, video, pdf

    init?(_ formats: [FileFormat], writable: Set<FileFormat>) {
        guard !formats.isEmpty else { return nil }
        if ToolCatalog.arePhotos(formats, writable: writable) { self = .photo }
        else if ToolCatalog.areVideos(formats) { self = .video }
        else if formats.allSatisfy({ $0 == .pdf }) { self = .pdf }
        else { return nil }
    }
}

/// The format chosen in the custom-size panel. Written on the main thread when the panel closes,
/// read by `makeRequest` just after; the lock keeps it safe if that ever changes.
final class CustomSizeChoice: @unchecked Sendable {
    private let lock = NSLock()
    private var image: FileFormat = .jpeg
    private var video: FileFormat?

    var imageTarget: FileFormat {
        get { lock.withLock { image } }
        set { lock.withLock { image = newValue } }
    }

    /// `nil` keeps each video's own format.
    var videoTarget: FileFormat? {
        get { lock.withLock { video } }
        set { lock.withLock { video = newValue } }
    }
}
