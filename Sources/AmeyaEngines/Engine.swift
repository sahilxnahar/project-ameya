import AmeyaCore
import Foundation

/// Picks the right engine for a conversion. Runs inside the worker process.
public enum Engine {
    /// Runs one job over one or more inputs (in order) and returns its outputs, all inside `scratch`.
    ///
    /// When `result.outputNames` is set the job produced a set of files (`outputs`, named as listed),
    /// which the worker sends as a TAR stream and the app places as a folder. Otherwise `outputs`
    /// holds exactly one file.
    ///
    /// Dispatch: `options.pdf` → `PDFTools`; otherwise a single input → `convert`.
    @MainActor
    public static func run(
        inputs: [URL],
        request: ConversionRequest,
        scratch: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (outputs: [URL], result: ConversionResult) {
        if let passport = request.options.passport {
            guard inputs.count == 1 else { throw ConversionError.invalidData("passport photos take one photo at a time") }
            return try PassportPhoto.run(passport, input: inputs[0], request: request, scratch: scratch, progress: progress)
        }
        if let action = request.options.pdf {
            return try PDFTools.run(action, inputs: inputs, request: request, scratch: scratch, progress: progress)
        }
        guard inputs.count == 1 else {
            throw ConversionError.invalidData("this conversion takes one file at a time")
        }
        let (output, result) = try await convert(input: inputs[0], request: request, scratch: scratch, progress: progress)
        return ([output], result)
    }

    /// Converts `input` and writes the result into the `scratch` folder.
    /// The target may equal the source when `request.options.hasEdits` (e.g. rotate a JPEG, keep JPEG).
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
        let editInPlace = source == target && request.options.hasEdits
        guard editInPlace || ConversionMatrix.canConvert(from: source, to: target)
                || ConversionMatrix.canEdit(source, options: request.options) else {
            throw ConversionError.unsupportedConversion(from: source, to: target)
        }
        let output = scratch.appendingPathComponent("output.\(target.preferredExtension)")
        var notes: [ConversionNote] = []
        var frames = 1

        switch (source.family, target.family) {
        case _ where target.isCompression || target == .decompressed:
            notes = try SingleFileCompression.convert(input: input, from: source, to: target, output: output, progress: progress)

        case _ where source.isFFmpegOnly || target.isFFmpegTarget:
            // Ogg, Opus, MP3 output, MKV, WebM, AVI…: the bundled LGPL FFmpeg helper.
            guard let helper = FFmpegAvailability.helperURL else { throw ConversionError.unsupportedConversion(from: source, to: target) }
            try await FFmpegConverter.convert(input: input, to: target, output: output, helper: helper, progress: progress)
            notes = ConversionMatrix(writable: [target]).possibleLosses(from: source, to: target)

        case _ where EverydayConverter.handles(source, target, options: request.options):
            notes = try EverydayConverter.convert(input: input, from: source, request: request, output: output, progress: progress)

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
            let (data, subtitleNotes) = try SubtitleConverter.convert(try read(input), from: source, to: target, options: request.options)
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
