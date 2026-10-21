import AmeyaCore
import Compression
import Foundation
import ModelIO

/// Keeps 3D models from pulling other files on the Mac into the output.
///
/// OBJ files name material libraries (`mtllib`), and USD layers name sublayers, references,
/// payloads, value clips and textures by path. Model I/O resolves those paths as it loads, so
/// `references = @/Users/someone/private.usdz@` would compose that file's geometry into the
/// result. Before loading, text formats have every link to somewhere outside the model's
/// folder replaced with a name that resolves to nothing. Binary USD can't be rewritten, so its
/// string table is read and the file refused if it links to another model outside; texture
/// links outside are removed from the loaded materials instead.
enum ModelReferences {
    /// A relative name that never exists next to the model: a missing layer is skipped with a warning.
    static let placeholder = "./ameya-link-removed.usda"
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "exr", "hdr", "tif", "tiff", "tga", "bmp", "gif",
                                               "webp", "heic", "heif", "ktx", "ktx2", "dds", "psd"]
    static let maxTokenBytes = 256 << 20

    enum Failure: Error, Equatable {
        case linksOutside
    }

    /// Whether a path in a model points outside the model's own folder: absolute, home-relative,
    /// with a scheme or drive letter, or climbing out with `..`.
    static func isOutside(_ path: String) -> Bool {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bracket = path.firstIndex(of: "[") { path = String(path[..<bracket]) } // package[inner] paths
        guard !path.isEmpty else { return false }
        if path.hasPrefix("/") || path.hasPrefix("~") || path.hasPrefix("\\") || path.contains(":") { return true }
        return path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..")
    }

    /// Prepares the model at `url` for loading. Returns whether links were removed.
    static func neutralize(_ url: URL) throws -> Bool {
        let ext = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        switch ext {
        case "obj":
            let (cleaned, removed) = neutralizeOBJ(data)
            if removed { try cleaned.write(to: url) }
            return removed
        case "usda", "usd", "usdc":
            if data.starts(with: Array("PXR-USDC".utf8)) {
                return try checkLinks(try crateTokens(data), onlyPathLike: true)
            }
            guard ext != "usdc" else { throw ConversionError.unreadable }
            let (cleaned, removed) = neutralizeUSDA(String(decoding: data, as: UTF8.self))
            if removed { try Data(cleaned.utf8).write(to: url) }
            return removed
        case "usdz":
            let layers = try ArchiveEntries.read(url) { ["usda", "usdc", "usd"].contains(($0 as NSString).pathExtension.lowercased()) }
            var removed = false
            for path in layers.paths {
                guard let layer = layers[path] else { continue }
                let binary = layer.starts(with: Array("PXR-USDC".utf8))
                let paths = binary ? try crateTokens(layer) : assetPaths(in: String(decoding: layer, as: UTF8.self))
                removed = try checkLinks(paths, onlyPathLike: binary) || removed
            }
            return removed
        default:
            return false
        }
    }

    /// Throws when `paths` link to another model or file outside; returns whether any outside
    /// link is a texture, to be removed from the loaded materials.
    private static func checkLinks(_ paths: [String], onlyPathLike: Bool = false) throws -> Bool {
        var textures = false
        for path in paths where isOutside(path) && (!onlyPathLike || looksLikeFilePath(path)) {
            let ext = (path as NSString).pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { throw Failure.linksOutside }
            textures = true
        }
        return textures
    }

    /// For the string table of a binary layer, which also holds names like `primvars:st`: a
    /// string with a path separator (or `~`) and a file extension.
    static func looksLikeFilePath(_ string: String) -> Bool {
        guard string.contains("/") || string.contains("\\") || string.hasPrefix("~") else { return false }
        let last = string.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let name = last.split(separator: "[").first.map(String.init) ?? last
        let ext = (name as NSString).pathExtension
        return !ext.isEmpty && ext.count <= 6 && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    // MARK: OBJ

    /// Drops `mtllib`/`maplib` lines naming files outside, and `call`/`csh` lines always.
    static func neutralizeOBJ(_ data: Data) -> (Data, Bool) {
        let newline = UInt8(ascii: "\n")
        var lines: [Data.SubSequence] = []
        var removed = false
        for line in data.split(separator: newline, omittingEmptySubsequences: false) {
            let words = String(decoding: line, as: UTF8.self).split(whereSeparator: \.isWhitespace)
            let keyword = words.first.map { $0.lowercased() } ?? ""
            let drop = keyword == "call" || keyword == "csh"
                || ((keyword == "mtllib" || keyword == "maplib") && words.dropFirst().contains { isOutside(String($0)) })
            if drop {
                removed = true
                continue
            }
            lines.append(line)
        }
        return (Data(lines.joined(separator: [newline])), removed)
    }

    // MARK: USDA

    /// Replaces each `@path@` (or `@@@path@@@`) outside the model with the placeholder.
    static func neutralizeUSDA(_ text: String) -> (String, Bool) {
        var removed = false
        let result = scanAssetPaths(text) { path in
            guard isOutside(path) else { return nil }
            removed = true
            return placeholder
        }
        return (result, removed)
    }

    /// Every asset path in a text layer.
    static func assetPaths(in text: String) -> [String] {
        var paths: [String] = []
        _ = scanAssetPaths(text) { paths.append($0); return nil }
        return paths
    }

    /// Walks a USDA layer, skipping strings and comments, calling `replace` for each asset path;
    /// a non-nil result replaces it.
    private static func scanAssetPaths(_ text: String, replace: (String) -> String?) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        func starts(_ literal: String, at position: Int) -> Bool {
            let letters = Array(literal.unicodeScalars)
            return position + letters.count <= scalars.count && Array(scalars[position..<position + letters.count]) == letters
        }
        func copy(to end: Int) {
            output.append(contentsOf: scalars[index..<min(end, scalars.count)])
            index = min(end, scalars.count)
        }
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "#" {
                var end = index
                while end < scalars.count, scalars[end] != "\n" { end += 1 }
                copy(to: end)
            } else if scalar == "\"" || scalar == "'" {
                let quote = String(scalar), triple = String(repeating: quote, count: 3)
                let delimiter = starts(triple, at: index) ? triple : quote
                var end = index + delimiter.unicodeScalars.count
                while end < scalars.count, !starts(delimiter, at: end) {
                    end += scalars[end] == "\\" ? 2 : 1
                }
                copy(to: end + delimiter.unicodeScalars.count)
            } else if scalar == "@" {
                let delimiter = starts("@@@", at: index) ? "@@@" : "@"
                let start = index + delimiter.unicodeScalars.count
                var end = start
                while end < scalars.count, !starts(delimiter, at: end), delimiter == "@@@" || scalars[end] != "\n" { end += 1 }
                guard end < scalars.count, starts(delimiter, at: end) else {
                    copy(to: end)
                    continue
                }
                let path = String(String.UnicodeScalarView(scalars[start..<end]))
                if let replacement = replace(path) {
                    output.append(contentsOf: (delimiter + replacement + delimiter).unicodeScalars)
                    index = end + delimiter.unicodeScalars.count
                } else {
                    copy(to: end + delimiter.unicodeScalars.count)
                }
            } else {
                output.append(scalar)
                index += 1
            }
        }
        return String(output)
    }

    // MARK: USDC

    /// The string table of a binary USD ("crate") layer, where every asset path, sublayer and
    /// reference is stored.
    static func crateTokens(_ data: Data) throws -> [String] {
        let bytes = [UInt8](data)
        func u64(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 8 <= bytes.count else { throw ConversionError.unreadable }
            let value = (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
            guard value <= UInt64(Int.max) else { throw ConversionError.unreadable }
            return Int(value)
        }
        guard bytes.count >= 88, bytes.starts(with: Array("PXR-USDC".utf8)) else { throw ConversionError.unreadable }
        let version = (Int(bytes[8]), Int(bytes[9]))
        let toc = try u64(16)
        let sections = try u64(toc)
        guard sections < 64 else { throw ConversionError.unreadable }
        var tokensStart: Int?
        for section in 0..<sections {
            let entry = toc + 8 + section * 32
            guard entry + 32 <= bytes.count else { throw ConversionError.unreadable }
            let name = String(decoding: bytes[entry..<entry + 16].prefix { $0 != 0 }, as: UTF8.self)
            if name == "TOKENS" { tokensStart = try u64(entry + 16) }
        }
        guard let start = tokensStart else { return [] }
        let count = try u64(start)
        var characters: [UInt8]
        if version < (0, 4) {
            let size = try u64(start + 8)
            guard size <= maxTokenBytes, start + 16 + size <= bytes.count else { throw ConversionError.unreadable }
            characters = Array(bytes[(start + 16)..<(start + 16 + size)])
        } else {
            let size = try u64(start + 8), compressedSize = try u64(start + 16)
            let body = start + 24
            guard size <= maxTokenBytes, compressedSize >= 1, body + compressedSize <= bytes.count else { throw ConversionError.unreadable }
            characters = try decompressFast(Array(bytes[body..<(body + compressedSize)]), size: size)
        }
        let tokens = characters.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard tokens.count >= count else { throw ConversionError.unreadable }
        return Array(tokens.prefix(count))
    }

    /// USD's "fast compression": a chunk count byte, then one LZ4 block (count 0) or that many
    /// blocks each preceded by its 32-bit size.
    private static func decompressFast(_ input: [UInt8], size: Int) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: size)
        var written = 0
        func decode(_ block: ArraySlice<UInt8>) throws {
            let room = size - written
            guard room > 0, !block.isEmpty else { throw ConversionError.unreadable }
            let produced = block.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    compression_decode_buffer(destination.baseAddress! + written, room, source.baseAddress!, source.count, nil, COMPRESSION_LZ4_RAW)
                }
            }
            guard produced > 0 else { throw ConversionError.unreadable }
            written += produced
        }
        let chunks = Int(input[0])
        if chunks == 0 {
            try decode(input[1...])
        } else {
            var offset = 1
            for _ in 0..<chunks {
                guard offset + 4 <= input.count else { throw ConversionError.unreadable }
                let length = Int(Int32(littleEndian: input[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
                offset += 4
                guard length > 0, offset + length <= input.count else { throw ConversionError.unreadable }
                try decode(input[offset..<offset + length])
                offset += length
            }
        }
        guard written == size else { throw ConversionError.unreadable }
        return output
    }

    // MARK: Loaded materials

    /// Removes material properties (textures, file names) that point outside `folder`.
    static func stripOutsideTextures(_ asset: MDLAsset, folder: URL) -> Bool {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        func outside(_ url: URL?) -> Bool {
            guard let url else { return false }
            guard url.isFileURL else { return true }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            return !path.hasPrefix(base + "/")
        }
        var removed = false
        for case let mesh as MDLMesh in asset.childObjects(of: MDLMesh.self) {
            for case let submesh as MDLSubmesh in mesh.submeshes ?? [] {
                guard let material = submesh.material else { continue }
                let doomed = (0..<material.count).compactMap { material[$0] }.filter { property in
                    switch property.type {
                    case .URL: outside(property.urlValue)
                    case .string: property.stringValue.map(isOutside) ?? false
                    case .texture: outside((property.textureSamplerValue?.texture as? MDLURLTexture)?.url)
                    default: false
                    }
                }
                for property in doomed { material.remove(property) }
                removed = removed || !doomed.isEmpty
            }
        }
        return removed
    }
}
