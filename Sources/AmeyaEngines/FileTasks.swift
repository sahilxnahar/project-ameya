import AmeyaCore
import CryptoKit
import Foundation

/// Runs a `FileTask` (privacy check, cleaning, photo details, checksum) inside the worker.
///
/// The file is identified by its contents, not the format the app guessed from its name, because
/// a privacy check must not be fooled by a renamed file. Reports are written as JSON outputs.
enum FileTasks {
    @MainActor
    static func run(
        _ task: FileTask,
        inputs: [URL],
        request: ConversionRequest,
        scratch: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (outputs: [URL], result: ConversionResult) {
        guard inputs.count == 1 else { throw ConversionError.invalidData("this tool takes one file at a time") }
        let input = inputs[0]
        let kind = PrivacyKind.detect(input, claimed: request.source)

        switch task {
        case .inspect:
            let report: PrivacyReport = switch kind {
            case .photo: try ImageInspector.inspect(input)
            case .pdf: try PDFPrivacy.inspect(input)
            case .office, .epub: try OfficePrivacy.inspect(input)
            case .media: try await MediaPrivacy.inspect(input, claimed: request.source)
            case .other: PrivacyReport(kind: .other, canClean: false,
                                       kept: ["Ameya doesn't know how to look inside this kind of file yet."])
            }
            progress(1)
            return try write(report.encoded(), named: "report.json", in: scratch)

        case .checksum(let algorithms):
            let report = try checksum(input, algorithms: algorithms.isEmpty ? [.sha256] : algorithms, progress: progress)
            return try write(report.encoded(), named: "checksum.json", in: scratch)

        case .editDetails(let edit):
            guard kind == .photo else { throw ConversionError.refused("Details can only be edited in photos.") }
            let output = scratch.appendingPathComponent("output.\(request.target.preferredExtension)")
            let notes = try PhotoDetailsWriter.write(edit, input: input, output: output, target: request.target)
            progress(1)
            return ([output], result(output, notes))

        case .clean:
            let output = scratch.appendingPathComponent("output.\(outputExtension(for: request, input: input))")
            var notes: [ConversionNote]
            switch kind {
            case .photo:
                // The existing photo cleaner: re-saves the pixels with only resolution and orientation.
                var photo = request
                photo.options.task = nil
                photo.options.image = ImageEdits(metadata: .removeAll)
                if photo.target == .other { photo.target = .jpeg }
                let (converted, conversion) = try await Engine.convert(input: input, request: photo, scratch: scratch, progress: progress)
                return ([converted], conversion)
            case .pdf: notes = try PDFPrivacy.clean(input, output: output)
            case .office: notes = try OfficeCleaner.clean(input, output: output)
            case .media: notes = try await MediaPrivacy.clean(input, claimed: request.source, output: output, progress: progress)
            case .epub, .other:
                throw ConversionError.refused("Ameya can't remove hidden details from this kind of file yet.")
            }
            progress(1)
            return ([output], result(output, notes))
        }
    }

    private static func write(_ data: Data, named name: String, in scratch: URL) throws -> ([URL], ConversionResult) {
        let output = scratch.appendingPathComponent(name)
        try data.write(to: output)
        return ([output], ConversionResult(outputBytes: data.count, frames: 1, notes: []))
    }

    private static func result(_ output: URL, _ notes: [ConversionNote]) -> ConversionResult {
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        return ConversionResult(outputBytes: size, frames: 1, notes: notes)
    }

    private static func outputExtension(for request: ConversionRequest, input: URL) -> String {
        request.target == .other ? (input.pathExtension.isEmpty ? "bin" : input.pathExtension) : request.target.preferredExtension
    }

    // MARK: Checksums

    /// Reads the file in 4 MB chunks, feeding every requested hash at once.
    static func checksum(_ url: URL, algorithms: [ChecksumAlgorithm],
                         progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> ChecksumReport {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = max(1, (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 1)
        var sha256 = SHA256(), sha1 = Insecure.SHA1(), md5 = Insecure.MD5()
        let wanted = Set(algorithms)
        var read: Int64 = 0
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            if wanted.contains(.sha256) { sha256.update(data: chunk) }
            if wanted.contains(.sha1) { sha1.update(data: chunk) }
            if wanted.contains(.md5) { md5.update(data: chunk) }
            read += Int64(chunk.count)
            progress(min(0.99, Double(read) / Double(total)))
        }
        func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
            digest.map { String(format: "%02x", $0) }.joined()
        }
        var digests: [ChecksumAlgorithm: String] = [:]
        if wanted.contains(.sha256) { digests[.sha256] = hex(sha256.finalize()) }
        if wanted.contains(.sha1) { digests[.sha1] = hex(sha1.finalize()) }
        if wanted.contains(.md5) { digests[.md5] = hex(md5.finalize()) }
        progress(1)
        return ChecksumReport(bytes: read, digests: digests)
    }
}

/// What kind of file this really is, for privacy purposes.
enum PrivacyKind {
    case photo, pdf, office, epub, media, other

    static func detect(_ url: URL, claimed: FileFormat?) -> PrivacyKind {
        var header = Data()
        if let handle = try? FileHandle(forReadingFrom: url) {
            header = (try? handle.read(upToCount: FileFormat.headerLength)) ?? Data()
            try? handle.close()
        }
        let bytes = [UInt8](header)
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            return OfficePrivacy.packageKind(url).map { $0 == .epub ? .epub : .office } ?? .other
        }
        let sniffed = FileFormat.sniff(header)
        if sniffed == .pdf { return .pdf }
        if let sniffed, sniffed.family == .image, sniffed != .svg { return .photo }
        if let format = sniffed ?? claimed, format.family == .audio || format.family == .video { return .media }
        // Formats with weak signatures (MP3 without ID3, Camera RAW): trust the claim if it fits.
        if let claimed, claimed.family == .image, claimed != .svg, sniffed == nil { return .photo }
        return .other
    }
}
