using System.Text;

namespace Ameya.Core.Formats;

/// <summary>
/// Detects a file's format from its first bytes, using the extension only to break ties the
/// contents can't settle. A line-by-line port of the Mac's FormatDetection.swift; the shared
/// detection vectors (spec/detection-vectors.json) keep the two in step.
/// </summary>
public static partial class FormatDetection
{
    /// <summary>Bytes read from the start of a file. TAR and DICOM signatures sit past byte 128.</summary>
    public const int HeaderLength = 512;

    private static FormatCatalog Catalog => FormatCatalog.Shared;

    /// <summary>ZIP-based formats that are not plain archives; these are never offered ZIP conversions.</summary>
    private static readonly HashSet<string> ZipBasedDocuments = new(StringComparer.Ordinal)
    {
        "xlsx", "pptx", "jar", "apk", "ipa", "pages", "numbers", "key", "odp", "ods",
        "sketch", "xpi", "whl", "nupkg", "vsix", "aar", "kmz", "3mf",
    };

    private static readonly HashSet<string> IsoMedia = new(StringComparer.Ordinal) { "mp4", "mov", "m4v", "m4a", "3gp" };

    /// <summary>Text formats with no reliable signature: the extension decides when the bytes look like text.
    /// YAML and XLSX are left out (Ameya only writes them); MicroDVD too (.sub is also binary VobSub).</summary>
    private static readonly HashSet<string> TextFormats = new(StringComparer.Ordinal)
    {
        "txt", "srt", "vtt", "html", "md", "csv", "tsv", "json", "xml", "plist",
        "ass", "ssa", "sbv", "ttml", "lrc", "smi", "vcf", "gpx", "kml", "geojson", "obj", "sql",
    };

    /// <summary>Names that promise a compressed TAR archive.</summary>
    private static readonly string[] CompressedTarSuffixes =
        [".tar.gz", ".tar.gzip", ".tgz", ".tar.bz2", ".tbz2", ".tbz", ".tar.xz", ".txz"];

    /// <summary>Detects the format of a file on disk. Null when it isn't recognised.</summary>
    public static FileFormat? Detect(string path)
    {
        var header = ReadHeader(path, HeaderLength);
        var fileName = Path.GetFileName(path);
        return RefineCompressed(Detect(header, PathExtension(fileName)), fileName);
    }

    /// <summary>Like <see cref="Detect(string)"/>, but any other non-empty file becomes "other",
    /// so it can still be compressed. Folders and empty files stay unsupported.</summary>
    public static FileFormat? DetectForConversion(string path)
    {
        if (Detect(path) is { } format) return format;
        var info = new FileInfo(path);
        return info.Exists && info.Length > 0 ? Catalog.Find("other") : null;
    }

    public static FileFormat? Detect(ReadOnlySpan<byte> header, string fileExtension) =>
        Catalog.Find(DetectId(header.ToArray(), fileExtension));

    /// <summary>Identifies a format from the first bytes alone. Null when unsure.</summary>
    public static FileFormat? Sniff(ReadOnlySpan<byte> header) => Catalog.Find(SniffId(header.ToArray()));

    /// <summary>The extension the way Foundation's pathExtension sees it: "a.tar.gz" → "gz", "a" → "".</summary>
    public static string PathExtension(string fileName)
    {
        var dot = fileName.LastIndexOf('.');
        return dot <= 0 || dot == fileName.Length - 1 ? "" : fileName[(dot + 1)..];
    }

    internal static byte[] ReadHeader(string path, int count)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var buffer = new byte[count];
            var total = 0;
            int read;
            while (total < count && (read = stream.Read(buffer, total, count - total)) > 0) total += read;
            return buffer[..total];
        }
        catch (IOException) { return []; }
        catch (UnauthorizedAccessException) { return []; }
    }

    /// <summary>Gzip, bzip2 and xz all sniff as compressed TARs. Nothing is decompressed to look
    /// inside, so the name decides: ".tar.gz", ".tgz" and friends are archives, any other is one
    /// compressed file whose only target is "Decompress".</summary>
    public static FileFormat? RefineCompressed(FileFormat? format, string fileName)
    {
        var single = format?.Id switch { "tgz" => "gz", "tbz2" => "bz2", "txz" => "xz", _ => null };
        if (single is null) return format;
        var name = fileName.ToLowerInvariant();
        return CompressedTarSuffixes.Any(suffix => name.EndsWith(suffix, StringComparison.Ordinal)) ? format : Catalog.Get(single);
    }

    private static string? DetectId(byte[] header, string fileExtension)
    {
        var ext = fileExtension.ToLowerInvariant();
        var byExtension = Catalog.FromExtension(fileExtension)?.Id;
        var bytes = header.Length > HeaderLength ? header[..HeaderLength] : header;

        // Containers whose first bytes don't say what's inside.
        if (StartsWith(bytes, [0x50, 0x4B, 0x03, 0x04]) || StartsWith(bytes, [0x50, 0x4B, 0x05, 0x06]))
        {
            if (byExtension is "docx" or "odt" or "kmz") return byExtension;
            if (DetectBook(bytes, ext, isZip: true) is { } book) return book;
            if (IsUsdz(bytes, ext)) return "usdz";
            return ZipBasedDocuments.Contains(ext) ? null : "zip";
        }
        if (StartsWith(bytes, [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])) // OLE compound file
        {
            return byExtension == "doc" ? "doc" : null;
        }

        if (SniffId(header) is { } sniffed)
        {
            // ISO media files share brands loosely; trust a matching extension within the group.
            if (IsoMedia.Contains(sniffed) && byExtension is not null && IsoMedia.Contains(byExtension)) return byExtension;
            if (sniffed == "tiff" && byExtension == "raw") return "raw"; // most camera RAW files are TIFF underneath
            if (sniffed == "rar" && DetectBook(bytes, ext, isZip: false) is { } comic) return comic;
            if (sniffed == "tgz" && byExtension == "svg") return "svg"; // .svgz is plain gzip
            if (sniffed == "mpg" && ext == "sub") return null; // VobSub, not a video Ameya can read
            return sniffed;
        }
        // An SVG whose root element sits past the header (e.g. after a long comment).
        if (byExtension == "svg" && LooksLikeText(bytes) && SvgRoot(bytes).Kind == SvgRootKind.Undetermined) return "svg";

        // Binary formats with no usable signature.
        if (byExtension is "tga" or "raw" or "stl" && bytes.Length > 0) return byExtension;
        if (SniffSubtitleText(bytes, byExtension) is { } subtitle) return subtitle;
        if (byExtension is not null && TextFormats.Contains(byExtension) && LooksLikeText(bytes))
        {
            return byExtension == "json" && LooksLikeGeoJson(bytes) ? "geojson" : byExtension;
        }
        return null;
    }

    /// <summary>Recognises a ZIP- or RAR-based book. EPUB puts an uncompressed "mimetype" entry
    /// first, so "application/epub+zip" sits at byte 38. Comics are told apart by extension.</summary>
    private static string? DetectBook(byte[] bytes, string ext, bool isZip)
    {
        if (isZip)
        {
            var name = "mimetype"u8;
            var type = "application/epub+zip"u8;
            if (bytes.Length >= 38 + type.Length && bytes.AsSpan(30, 8).SequenceEqual(name) &&
                bytes.AsSpan(38, type.Length).SequenceEqual(type))
            {
                return "epub";
            }
            if (ext == "epub") return "epub";
        }
        return ext switch { "cbz" => "cbz", "cbr" => "cbr", _ => null };
    }

    /// <summary>A USDZ package is an uncompressed ZIP whose first entry is a USD layer.</summary>
    private static bool IsUsdz(byte[] bytes, string ext)
    {
        if (ext == "usdz") return true;
        if (bytes.Length <= 30) return false;
        var nameLength = bytes[26] | (bytes[27] << 8);
        if (nameLength <= 5 || bytes.Length < 30 + nameLength) return false;
        var name = Encoding.UTF8.GetString(bytes, 30, nameLength).ToLowerInvariant();
        return name.EndsWith(".usdc", StringComparison.Ordinal) || name.EndsWith(".usda", StringComparison.Ordinal);
    }

    internal static bool StartsWith(byte[] bytes, ReadOnlySpan<byte> prefix, int offset = 0) =>
        bytes.Length >= offset + prefix.Length && bytes.AsSpan(offset, prefix.Length).SequenceEqual(prefix);

    /// <summary>The original file name stored in a gzip header (FNAME), reduced to a safe visible name.</summary>
    public static string? GzipOriginalName(ReadOnlySpan<byte> header)
    {
        var bytes = header.Length > 4096 ? header[..4096] : header;
        if (bytes.Length <= 10 || bytes[0] != 0x1F || bytes[1] != 0x8B || bytes[2] != 8) return null;
        var flags = bytes[3];
        var index = 10;
        if ((flags & 0x04) != 0) // FEXTRA
        {
            if (index + 2 > bytes.Length) return null;
            index += 2 + (bytes[index] | (bytes[index + 1] << 8));
        }
        if ((flags & 0x08) == 0 || index >= bytes.Length) return null;
        var end = bytes[index..].IndexOf((byte)0);
        if (end < 0) return null;
        var raw = Encoding.Latin1.GetString(bytes.Slice(index, end));
        var name = raw.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "";
        name = name.TrimStart('.');
        if (name.Length == 0 || name.Any(c => c < 0x20 || c == ':')) return null;
        return name;
    }
}
