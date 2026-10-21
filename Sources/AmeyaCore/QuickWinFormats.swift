import Foundation
import ModelIO

// 3D models, single compressed files (.gz, .bz2, .xz) and SQLite databases.
// Their detection and routing rules live here so the shared tables stay short.

extension FileFormat {
    /// Targets of "Compress": any single file can be squeezed into one of these.
    public var isCompression: Bool { self == .gz || self == .bz2 || self == .xz }

    /// The single-file counterpart of a compressed TAR (.tar.gz → .gz), or nil.
    var singleFileVariant: FileFormat? {
        switch self {
        case .tgz: .gz
        case .tbz2: .bz2
        case .txz: .xz
        default: nil
        }
    }

    /// Model formats this Mac can write. USDZ goes through SceneKit; the rest through Model I/O.
    static func modelWritable(_ format: FileFormat) -> Bool {
        switch format {
        case .usdz: true
        case .abc: false // read only
        default: MDLAsset.canExportFileExtension(format.preferredExtension)
        }
    }

    /// Like `detect(at:)`, but any other non-empty regular file is reported as `.other`,
    /// so it can still be compressed. Folders and empty files stay unsupported.
    public static func detectForConversion(at url: URL) -> FileFormat? {
        if let format = detect(at: url) { return format }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 else { return nil }
        return .other
    }

    /// A USDZ package is an uncompressed ZIP whose first entry is a USD layer.
    static func isUSDZ(_ bytes: [UInt8], fileExtension: String) -> Bool {
        if fileExtension.lowercased() == "usdz" { return true }
        guard bytes.count > 30 else { return false }
        let nameLength = Int(bytes[26]) | Int(bytes[27]) << 8
        guard nameLength > 5, bytes.count >= 30 + nameLength else { return false }
        let name = String(decoding: bytes[30..<30 + nameLength], as: UTF8.self).lowercased()
        return name.hasSuffix(".usdc") || name.hasSuffix(".usda")
    }

    // MARK: TAR archive or single compressed file?

    /// Names that promise a compressed TAR archive.
    static let compressedTarSuffixes = [".tar.gz", ".tar.gzip", ".tgz", ".tar.bz2", ".tbz2", ".tbz", ".tar.xz", ".txz"]

    /// Gzip, bzip2 and xz all sniff as compressed TARs. The app never decompresses anything to
    /// look inside (all parsing of file contents happens in the sandboxed worker), so the name
    /// decides: ".tar.gz"/".tgz" and friends are archives, every other one is a single compressed
    /// file. Its only target is "Decompress", and the worker reports when the result is a TAR.
    static func refineCompressed(_ format: FileFormat?, url: URL) -> FileFormat? {
        guard let format, let single = format.singleFileVariant else { return format }
        let name = url.lastPathComponent.lowercased()
        return compressedTarSuffixes.contains(where: name.hasSuffix) ? format : single
    }

    /// The original file name stored in a gzip header (the FNAME field), reduced to a safe,
    /// visible file name. Nil when absent.
    public static func gzipOriginalName(_ header: Data) -> String? {
        let bytes = [UInt8](header.prefix(4096))
        guard bytes.count > 10, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard index + 2 <= bytes.count else { return nil }
            index += 2 + (Int(bytes[index]) | Int(bytes[index + 1]) << 8)
        }
        guard flags & 0x08 != 0, index < bytes.count,
              let end = bytes[index...].firstIndex(of: 0),
              let raw = String(bytes: bytes[index..<end], encoding: .isoLatin1) else { return nil }
        var name = raw.split(separator: "/").last.map(String.init) ?? ""
        while name.hasPrefix(".") { name.removeFirst() }
        guard !name.isEmpty, !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0 == ":" }) else { return nil }
        return name
    }
}

extension ConversionMatrix {
    /// Routes involving compression, 3D models or SQLite, or nil when none is involved.
    static func quickWinRoute(from source: FileFormat, to target: FileFormat) -> Bool? {
        if target.isCompression {
            // Archives already have compressed forms (.tar.gz), and compressing twice is pointless.
            // Write-only formats are never sources (their files arrive as `.other`).
            let writeOnly: Set<FileFormat> = [.alac, .yaml, .xlsx, .sql]
            return source == .other || !(writeOnly.contains(source) || [.archive, .compressed].contains(source.family))
        }
        if target == .decompressed { return source.isCompression }
        if source == .other || source.isCompression { return false }
        switch (source.family, target.family) {
        case (.model, .model): return target != .abc
        case (.model, .image): return target == .png
        case (.model, _), (_, .model): return false
        default: break
        }
        if source == .sqlite { return target == .csv || target == .json || target == .sql }
        if target == .sqlite || target == .sql { return false }
        return nil
    }

    /// What these conversions may lose, or nil when none is involved.
    static func quickWinLosses(from source: FileFormat, to target: FileFormat) -> [ConversionNote]? {
        if target.isCompression || target == .decompressed { return [] }
        switch (source.family, target.family) {
        case (.model, .model):
            return source == .obj ? [.materialsMayNotCarryOver, .separateTexturesNotIncluded] : [.materialsMayNotCarryOver]
        case (.model, _):
            return []
        default:
            break
        }
        guard source == .sqlite else { return nil }
        switch target {
        case .csv: return [.onlyLargestTableKept, .binaryAsBase64]
        case .json: return [.binaryAsBase64]
        default: return []
        }
    }
}
