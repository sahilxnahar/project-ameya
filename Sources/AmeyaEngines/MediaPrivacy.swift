import AmeyaCore
@preconcurrency import AVFoundation
import Foundation

/// Hidden details in sound and video files (QuickTime and MP4 atoms, iTunes tags, ID3, and, with
/// the bundled FFmpeg helper, Matroska/Ogg/AVI tags): where it was recorded (ISO 6709), the
/// phone or camera, the app and dates. Cleaning copies the streams untouched without them.
enum MediaPrivacy {
    typealias Finding = PrivacyReport.Finding

    /// Containers AVFoundation can copy without re-encoding.
    static let exportable: [FileFormat: AVFileType] = [.mp4: .mp4, .mov: .mov, .m4v: .m4v, .m4a: .m4a]

    static func format(of url: URL, claimed: FileFormat?) -> FileFormat? {
        let header = (try? FileHandle(forReadingFrom: url)).flatMap { try? $0.read(upToCount: FileFormat.headerLength) } ?? Data()
        let sniffed = FileFormat.sniff(header)
        // ISO media brands overlap; the app's claim (from the name) breaks the tie.
        if let claimed, let sniffed, exportable[sniffed] != nil, exportable[claimed] != nil { return claimed }
        return sniffed ?? claimed
    }

    static func canClean(_ format: FileFormat?) -> Bool {
        guard let format else { return false }
        return exportable[format] != nil || FFmpegAvailability.isAvailable
    }

    static func inspect(_ url: URL, claimed: FileFormat?) async throws -> PrivacyReport {
        let format = format(of: url, claimed: claimed)
        var pairs: [(String, String)] = []
        if format?.isFFmpegOnly != true, let found = try? await avPairs(url) {
            pairs = found
        } else if let helper = FFmpegAvailability.helperURL {
            pairs = try await ffmpegPairs(url, helper: helper)
        } else {
            return PrivacyReport(kind: .media, canClean: false,
                                 kept: ["Ameya can't look inside this kind of file without its media helper."])
        }
        var seen: Set<String> = []
        let findings = pairs.compactMap(classify).filter { seen.insert("\($0.label)|\($0.value)").inserted }
        let clean = canClean(format)
        return PrivacyReport(kind: .media, findings: findings, canClean: clean,
                             kept: clean ? [] : ["Ameya can't remove details from this kind of file without its media helper."])
    }

    /// (identifier, text) for every metadata item in the file and its tracks.
    static func avPairs(_ url: URL) async throws -> [(String, String)] {
        let asset = AVURLAsset(url: url)
        var items: [AVMetadataItem] = []
        for format in try await asset.load(.availableMetadataFormats) {
            items += try await asset.loadMetadata(for: format)
        }
        for track in try await asset.load(.tracks) {
            items += (try? await track.load(.metadata)) ?? []
        }
        var pairs: [(String, String)] = []
        for item in items.prefix(500) {
            let key = item.identifier?.rawValue ?? (item.key as? String) ?? ""
            var value = try? await item.load(.stringValue)
            if value == nil, let date = try? await item.load(.dateValue) { value = ISO8601DateFormatter().string(from: date) }
            if value == nil, let number = try? await item.load(.numberValue) { value = number.stringValue }
            if let value, !value.isEmpty { pairs.append((key, value)) }
        }
        return pairs
    }

    /// FFmpeg's metadata dump ("key=value" lines; sections in brackets).
    static func ffmpegPairs(_ url: URL, helper: URL) async throws -> [(String, String)] {
        let lines = LineBox()
        let run = try await FFmpegConverter.execute(helper, ["-hide_banner", "-nostdin", "-i", url.path, "-f", "ffmetadata", "-"]) {
            lines.append($0)
        }
        guard run.status == 0 else { throw ConversionError.unreadable }
        return lines.all.compactMap { line in
            guard !line.hasPrefix(";"), !line.hasPrefix("["), let equals = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<equals]), String(line[line.index(after: equals)...]))
        }
    }

    /// Puts one tag in a group, or nil for tags that only describe the streams.
    static func classify(_ key: String, _ value: String) -> Finding? {
        let lower = key.lowercased()
        let name = lower.split(separator: "/").last.map(String.init) ?? lower
        func finding(_ group: PrivacyReport.Group, _ label: String, _ text: String = value) -> Finding {
            Finding(group: group, label: label, value: text)
        }
        if name.contains("location") || name.hasSuffix("xyz") || name == "loci" {
            return finding(.location, "Recorded at (latitude, longitude)", iso6709(value) ?? value)
        }
        if name.contains("serial") { return finding(.device, "Device serial number") }
        if name.hasSuffix(".make") || name == "make" || name.hasSuffix("mak") { return finding(.device, "Device maker") }
        if name.hasSuffix(".model") || name == "model" || name.hasSuffix("mod") { return finding(.device, "Device") }
        if name.contains("lens") || name.contains("camera") { return finding(.device, "Camera") }
        if name.contains("software") || name.hasSuffix("swr") || name.hasSuffix("too") || name == "encoder" || name.contains("encodedby") || name == "tsse" || name == "tenc" {
            return finding(.edits, "Made with")
        }
        if name.contains("creationdate") || name == "creation_time" || name.hasSuffix("day") || name == "date" || name == "tdrc" {
            return finding(.edits, "Recorded or made")
        }
        if name.contains("author") || name.contains("artist") || name.hasSuffix("art") || name == "tpe1" || name.contains("composer")
            || name.contains("copyright") || name.hasSuffix("cpy") || name == "tcop" || name.contains("owner") {
            return finding(.name, "Author or artist")
        }
        if ["major_brand", "minor_version", "compatible_brands", "handler_name", "vendor_id", "language"].contains(name)
            || name.contains("duration") {
            return nil
        }
        if name.contains("title") || name.hasSuffix("nam") || name == "tit2" { return finding(.other, "Title") }
        if name.contains("comment") || name.hasSuffix("cmt") || name.contains("description") || name.hasSuffix("des") {
            return finding(.other, "Comment")
        }
        return finding(.other, "Tag “\(PrivacyReport.clip(name, limit: 40))”")
    }

    /// "+51.5007-000.1246+010.000/" → "51.50070, -0.12460".
    static func iso6709(_ text: String) -> String? {
        guard let match = text.firstMatch(of: #/^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)/#),
              let latitude = Double(match.output.1), let longitude = Double(match.output.2) else { return nil }
        return String(format: "%.5f, %.5f", latitude, longitude)
    }

    // MARK: Cleaning

    static func clean(_ input: URL, claimed: FileFormat?, output: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> [ConversionNote] {
        let format = format(of: input, claimed: claimed)
        if let format, let fileType = exportable[format] {
            // A composition of the tracks carries none of the file's or tracks' metadata (an export
            // session given `metadata = []` would quietly copy the source's again).
            let asset = AVURLAsset(url: input)
            let composition = AVMutableComposition()
            let duration = try await asset.load(.duration)
            for track in try await asset.load(.tracks) {
                let type = track.mediaType
                guard [.video, .audio, .subtitle, .closedCaption, .text, .timecode].contains(type),
                      let copy = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try copy.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
                copy.preferredTransform = try await track.load(.preferredTransform)
                copy.languageCode = try? await track.load(.languageCode)
            }
            guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
                  session.supportedFileTypes.contains(fileType) else {
                throw ConversionError.mediaFailed("the file couldn't be copied")
            }
            session.outputURL = output
            session.outputFileType = fileType
            session.metadata = []
            session.metadataItemFilter = .forSharing()
            let box = MediaExportBox(session)
            await box.session.export()
            guard box.session.status == .completed else {
                throw ConversionError.mediaFailed(box.session.error?.localizedDescription ?? "the file couldn't be copied")
            }
            return [.hiddenDetailsRemoved]
        }
        guard let helper = FFmpegAvailability.helperURL else {
            throw ConversionError.refused("Ameya can't remove details from this kind of file without its media helper.")
        }
        let run = try await FFmpegConverter.execute(helper, [
            "-hide_banner", "-nostdin", "-y", "-i", input.path, "-map", "0", "-map_metadata", "-1", "-map_chapters", "-1",
            "-c", "copy", "-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact", output.path,
        ]) { _ in }
        guard run.status == 0 else { throw FFmpegConverter.error(from: run.stderr) }
        return [.hiddenDetailsRemoved]
    }
}

private final class MediaExportBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { if lines.count < 2_000 { lines.append(line) } } }
    var all: [String] { lock.withLock { lines } }
}
