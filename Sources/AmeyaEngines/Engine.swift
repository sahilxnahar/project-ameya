import AmeyaCore
import Foundation

/// Picks the right engine for a conversion. Runs inside the worker process.
public enum Engine {
    /// Converts `input` and writes the result into the `scratch` folder.
    /// Runs on the main actor because the system document readers (HTML, Word) require it;
    /// the worker has no UI, so nothing else competes for the main thread.
    @MainActor
    public static func convert(
        input: URL,
        request: ConversionRequest,
        scratch: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (output: URL, result: ConversionResult) {
        guard let source = request.source ?? FileFormat.detect(at: input) else { throw ConversionError.unreadable }
        let target = request.target
        guard ConversionMatrix.canConvert(from: source, to: target) else {
            throw ConversionError.unsupportedConversion(from: source, to: target)
        }
        let output = scratch.appendingPathComponent("output.\(target.preferredExtension)")
        var notes: [ConversionNote] = []
        var frames = 1

        switch (source.family, target.family) {
        case _ where target.isCompression || target == .decompressed:
            notes = try SingleFileCompression.convert(input: input, from: source, to: target, output: output, progress: progress)

        case (.model, _):
            notes = try ModelConverter.convert(input: input, to: target, output: output, progress: progress)

        case _ where source == .sqlite:
            notes = try SQLiteConverter.convert(input: input, to: target, output: output, progress: progress)

        case _ where source.isBookOrComic || target.isBookOrComic:
            (notes, frames) = try BookConverter.convert(input: input, from: source, to: target, output: output,
                                                        options: request.options, progress: progress)
        case _ where ConversionMatrix.isTranscription(from: source, to: target):
            notes = try await Transcriber.convert(
                input: input, to: target, output: output, scratch: scratch, options: request.options, progress: progress
            )

        case (.image, .image), (.image, .document), (.document, .image):
            let (data, result) = try ImageConverter.convert(try read(input), request: request, progress: progress)
            try data.write(to: output)
            notes = result.notes
            frames = result.frames

        case (.image, .video):
            notes = try await VideoConverter.gifToVideo(try read(input), to: target, output: output, options: request.options, progress: progress)

        case (.document, .document):
            let (data, documentNotes) = try DocumentConverter.convert(try read(input), from: source, to: target)
            try data.write(to: output)
            notes = documentNotes
            progress(1)

        case (.audio, .audio), (.video, .audio):
            try await AudioConverter.convert(input: input, to: target, output: output, progress: progress)
            notes = ConversionMatrix(writable: [target]).possibleLosses(from: source, to: target)

        case (.video, .video):
            try await VideoConverter.transcode(input: input, to: target, output: output, progress: progress)

        case (.video, .image):
            let (data, gifNotes) = try await VideoConverter.toGIF(input: input, progress: progress)
            try data.write(to: output)
            notes = gifNotes

        case (.archive, .archive):
            notes = try ArchiveConverter.repack(input: input, to: target, output: output, progress: progress)

        case (.subtitle, .subtitle):
            let (data, subtitleNotes) = try SubtitleConverter.convert(try read(input), from: source, to: target)
            try data.write(to: output)
            notes = subtitleNotes
            progress(1)

        case (.data, .data), (.data, .document):
            notes = try DataConverter.convert(input: input, from: source, to: target, output: output)
            progress(1)

        default:
            throw ConversionError.unsupportedConversion(from: source, to: target)
        }

        let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        return (output, ConversionResult(outputBytes: size, frames: frames, notes: notes))
    }

    private static func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ConversionError.unreadable
        }
    }
}
