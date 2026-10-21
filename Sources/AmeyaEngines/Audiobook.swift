import AmeyaCore
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Several sound files into one M4B audiobook: the sound is joined and encoded as AAC, then
/// copied (not re-encoded) into an MPEG-4 file with a chapter track — one 3GPP (tx3g) text sample
/// per file, linked to the sound as its chapter list — plus the title and an optional cover.
enum Audiobook {
    typealias Job = MediaToolbox.Job

    struct Chapter {
        var title: String
        var range: CMTimeRange
    }

    static func make(_ sounds: [URL], titles: [String], title: String?, cover: URL?, job: Job) async throws -> [ConversionNote] {
        guard !sounds.isEmpty else { throw ConversionError.refused("Add the sound files for the audiobook.") }
        let (composition, ranges) = try await AudioTools.sequence(sounds)
        var layout = try await AudioPipeline.layout(of: AVURLAsset(url: sounds[0]), target: .m4a)
        for sound in sounds.dropFirst() {
            layout.channels = max(layout.channels, try await AudioPipeline.layout(of: AVURLAsset(url: sound), target: .m4a).channels)
        }
        let encoded = job.temporary("book.m4a")
        // Speech needs less than music: 64 kbit/s per channel.
        try await AudioTools.writeSound(composition, layout: layout, chain: ProcessorChain([]), channels: layout.channels,
                                        source: sounds[0], isVideo: false, format: .m4a, to: encoded,
                                        bitRate: 64_000 * layout.channels, job: job.slice(from: 0, to: 0.85))
        let chapters = zip(titles, ranges).map { Chapter(title: $0.0, range: $0.1) }
        let artwork = cover.flatMap(coverJPEG(from:))
        try await write(sound: encoded, chapters: chapters, title: title, cover: artwork, to: job.output)
        var notes: [ConversionNote] = [.joinedInOrder, .chaptersAdded]
        if artwork != nil { notes.append(.coverAdded) }
        return notes
    }

    /// Copies the AAC sound into `output` with chapters and metadata.
    static func write(sound: URL, chapters: [Chapter], title: String?, cover: Data?, to output: URL) async throws {
        let asset = AVURLAsset(url: sound)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ConversionError.noAudioTrack }
        let duration = try await asset.load(.duration)
        let hint = try await track.load(.formatDescriptions).first

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(readerOutput)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
        audioInput.expectsMediaDataInRealTime = false
        let textFormat = try textFormatDescription()
        let textInput = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: textFormat)
        textInput.marksOutputTrackAsEnabled = false
        textInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput), writer.canAdd(textInput) else { throw ConversionError.mediaFailed("the audiobook couldn't be written") }
        writer.add(audioInput)
        writer.add(textInput)
        let chapterList = AVAssetTrack.AssociationType.chapterList.rawValue
        if audioInput.canAddTrackAssociation(withTrackOf: textInput, type: chapterList) {
            audioInput.addTrackAssociation(withTrackOf: textInput, type: chapterList)
        }
        writer.metadata = metadata(title: title, cover: cover)

        var samples: [CMSampleBuffer] = []
        for (index, chapter) in chapters.enumerated() {
            // The last chapter runs to the end of the sound.
            let end = index == chapters.count - 1 ? duration : chapter.range.end
            let range = CMTimeRange(start: chapter.range.start, end: end)
            samples.append(try textSample(chapter.title, range: range, format: textFormat))
        }

        guard reader.startReading() else { throw ConversionError.mediaFailed(reader.error?.localizedDescription ?? "couldn't read the sound") }
        guard writer.startWriting() else { throw ConversionError.mediaFailed(writer.error?.localizedDescription ?? "couldn't start writing") }
        writer.startSession(atSourceTime: .zero)
        let sound = SamplePump(input: audioInput, label: "sound") { readerOutput.copyNextSampleBuffer() }
        var queue = samples[...]
        let text = SamplePump(input: textInput, label: "chapters") { queue.popFirst() }
        let box = WriterBox(writer)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await sound.run(box) }
            group.addTask { await text.run(box) }
        }
        guard reader.status != .failed, writer.status == .writing else {
            writer.cancelWriting()
            throw ConversionError.mediaFailed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "the audiobook couldn't be written")
        }
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ConversionError.mediaFailed(writer.error?.localizedDescription ?? "the audiobook couldn't be written")
        }
    }

    static func metadata(title: String?, cover: Data?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        if let title, !title.isEmpty {
            for identifier in [AVMetadataIdentifier.iTunesMetadataSongName, .iTunesMetadataAlbum] {
                let item = AVMutableMetadataItem()
                item.identifier = identifier
                item.value = title as NSString
                items.append(item)
            }
        }
        if let cover {
            let item = AVMutableMetadataItem()
            item.identifier = .iTunesMetadataCoverArt
            item.value = cover as NSData
            item.dataType = kCMMetadataBaseDataType_JPEG as String
            items.append(item)
        }
        return items
    }

    /// The cover as JPEG, at most 1400 pixels on its longest side.
    static func coverJPEG(from url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1400,
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: Chapter text samples

    static func textFormatDescription() throws -> CMFormatDescription {
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor: [
                kCMTextFormatDescriptionColor_Red: 0, kCMTextFormatDescriptionColor_Green: 0,
                kCMTextFormatDescriptionColor_Blue: 0, kCMTextFormatDescriptionColor_Alpha: 255,
            ],
            kCMTextFormatDescriptionExtension_DefaultTextBox: [
                kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0,
                kCMTextFormatDescriptionRect_Bottom: 0, kCMTextFormatDescriptionRect_Right: 0,
            ],
            kCMTextFormatDescriptionExtension_DefaultStyle: [
                kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0,
                kCMTextFormatDescriptionStyle_Font: 1,
                kCMTextFormatDescriptionStyle_FontFace: 0, kCMTextFormatDescriptionStyle_FontSize: 12,
                kCMTextFormatDescriptionStyle_ForegroundColor: [
                    kCMTextFormatDescriptionColor_Red: 255, kCMTextFormatDescriptionColor_Green: 255,
                    kCMTextFormatDescriptionColor_Blue: 255, kCMTextFormatDescriptionColor_Alpha: 255,
                ],
            ],
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Sans-Serif"],
            kCMTextFormatDescriptionExtension_HorizontalJustification: 0,
            kCMTextFormatDescriptionExtension_VerticalJustification: 0,
        ]
        var description: CMFormatDescription?
        let status = CMFormatDescriptionCreate(allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Text,
                                               mediaSubType: kCMTextFormatType_3GText,
                                               extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw ConversionError.mediaFailed("chapters couldn't be prepared (\(status))") }
        return description
    }

    /// A 3GPP timed-text sample: a big-endian 16-bit length, then the UTF-8 text.
    static func textSample(_ text: String, range: CMTimeRange, format: CMFormatDescription) throws -> CMSampleBuffer {
        let utf8 = Array(text.utf8.prefix(1000))
        let bytes: [UInt8] = [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)] + utf8
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
                                                        blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                        offsetToData: 0, dataLength: bytes.count,
                                                        flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw ConversionError.mediaFailed("chapters couldn't be prepared (\(status))") }
        status = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        var timing = CMSampleTimingInfo(duration: range.duration, presentationTimeStamp: range.start, decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                                      makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: 1,
                                      sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw ConversionError.mediaFailed("chapters couldn't be prepared (\(status))") }
        return sample
    }
}

/// Feeds a writer input from `next` on its own queue until `next` runs out. AVFoundation objects
/// aren't Sendable; each pump touches its input only on its serial queue.
final class SamplePump: @unchecked Sendable {
    let input: AVAssetWriterInput
    let queue: DispatchQueue
    private let next: () -> CMSampleBuffer?
    private var finished = false

    init(input: AVAssetWriterInput, label: String, next: @escaping () -> CMSampleBuffer?) {
        self.input = input
        self.next = next
        queue = DispatchQueue(label: "org.ameya.media.\(label)")
    }

    func run(_ box: WriterBox) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard box.writer.status == .writing, let sample = next() else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    guard input.append(sample) else {
                        finished = true
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}

final class WriterBox: @unchecked Sendable {
    let writer: AVAssetWriter
    init(_ writer: AVAssetWriter) { self.writer = writer }
}
