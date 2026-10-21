using System.Text;

namespace Ameya.Core.Formats;

public static partial class FormatDetection
{
    /// <summary>Magic-byte signatures, in the same order as the Mac's sniff(_:) so ties resolve alike.</summary>
    private static string? SniffId(byte[] header)
    {
        var original = header.Length > HeaderLength ? header[..HeaderLength] : header;
        var bytes = StartsWith(original, [0xEF, 0xBB, 0xBF]) ? original[3..] : original; // UTF-8 BOM

        bool Starts(ReadOnlySpan<byte> prefix, int offset = 0) => StartsWith(bytes, prefix, offset);
        bool StartsText(string text, int offset = 0) => StartsWith(bytes, Encoding.UTF8.GetBytes(text), offset);

        // Images
        if (Starts([0xFF, 0xD8, 0xFF])) return "jpeg";
        if (Starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return "png";
        if (StartsText("GIF8")) return "gif";
        if (StartsText("IIRO") || StartsText("IIRS") || Starts([0x49, 0x49, 0x55, 0x00])) return "raw"; // Olympus, Panasonic
        if (StartsText("FUJIFILMCCD-RAW") || StartsText("FOVb")) return "raw"; // Fujifilm RAF, Sigma X3F
        if (Starts([0x49, 0x49, 0x2A, 0x00]) || Starts([0x4D, 0x4D, 0x00, 0x2A])) return "tiff";
        if (StartsText("RIFF") && StartsText("WEBP", 8)) return "webp";
        if (StartsText("BM") && bytes.Length >= 14) return "bmp";
        if (StartsText("8BPS")) return "psd";
        if (Starts([0x76, 0x2F, 0x31, 0x01])) return "exr";
        if (Starts([0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB])) return "ktx";
        if (Starts([0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB])) return "ktx2";
        if (Starts([0x13, 0xAB, 0xA1, 0x5C])) return "astc";
        if (StartsText("icns")) return "icns";
        if (Starts([0x00, 0x00, 0x01, 0x00]) && bytes.Length >= 6 && bytes[4] > 0 && bytes[5] == 0) return "ico";
        if (Starts([0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20]) || Starts([0xFF, 0x4F, 0xFF, 0x51])) return "jp2";
        if (Starts([0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20]) || Starts([0xFF, 0x0A])) return "jxl";
        if (StartsText("#?RADIANCE") || StartsText("#?RGBE")) return "hdr";
        if (Starts([0x01, 0xDA]) && bytes.Length >= 4 && bytes[2] <= 1) return "sgi";
        if (StartsText("DICM", 128)) return "dicom";
        if (bytes.Length >= 3 && bytes[0] == (byte)'P' && bytes[1] >= (byte)'1' && bytes[1] <= (byte)'6' &&
            bytes[2] is 0x20 or 0x09 or 0x0A or 0x0D)
        {
            return "pbm";
        }

        // Documents
        if (StartsText("%PDF")) return "pdf";
        if (StartsText("{\\rtf")) return "rtf";
        if (StartsText("WEBVTT")) return "vtt";
        var lowered = Encoding.UTF8.GetString(bytes, 0, Math.Min(32, bytes.Length)).Trim().ToLowerInvariant();
        if (lowered.StartsWith("<!doctype html", StringComparison.Ordinal) || lowered.StartsWith("<html", StringComparison.Ordinal)) return "html";
        if (SniffSubtitleSignature(bytes) is { } subtitle) return subtitle;

        if (SvgRoot(original).Kind == SvgRootKind.Svg) return "svg";
        if (lowered.StartsWith("begin:vcard", StringComparison.Ordinal)) return "vcf";
        if (lowered.StartsWith('<'))
        {
            var head = Encoding.UTF8.GetString(bytes);
            if (head.Contains("<gpx", StringComparison.Ordinal)) return "gpx";
            if (head.Contains("<kml", StringComparison.Ordinal)) return "kml";
        }

        // Data
        if (StartsText("bplist00")) return "plist";
        if (lowered.StartsWith("<?xml", StringComparison.Ordinal) || lowered.StartsWith("<plist", StringComparison.Ordinal))
        {
            var whole = Encoding.UTF8.GetString(bytes).ToLowerInvariant();
            if (whole.Contains("<!doctype plist", StringComparison.Ordinal) || whole.Contains("<plist", StringComparison.Ordinal)) return "plist";
            if (whole.Contains("<!doctype html", StringComparison.Ordinal) || whole.Contains("<html", StringComparison.Ordinal)) return "html"; // XHTML
            return "xml";
        }

        // MPEG-TS: a 0x47 sync byte every 188 bytes; Blu-ray M2TS adds a 4-byte prefix to each packet.
        foreach (var (offset, stride) in new[] { (0, 188), (4, 192) })
        {
            if (bytes.Length > offset + 2 * stride &&
                bytes[offset] == 0x47 && bytes[offset + stride] == 0x47 && bytes[offset + 2 * stride] == 0x47)
            {
                return "ts";
            }
        }

        // Audio
        if (StartsText("ID3")) return "mp3";
        if (bytes.Length >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 && (bytes[1] & 0x06) != 0)
        {
            return "mp3"; // MPEG audio frame sync with a non-zero layer (ADTS AAC has layer 0)
        }
        if (StartsText("RIFF") && StartsText("WAVE", 8)) return "wav";
        if (StartsText("FORM") && (StartsText("AIFF", 8) || StartsText("AIFC", 8))) return "aiff";
        if (StartsText("fLaC")) return "flac";
        if (StartsText("caff")) return "caf";
        if (StartsText("OggS")) return StartsText("OpusHead", 28) ? "opus" : "ogg";

        // Video containers
        if (Starts([0x1A, 0x45, 0xDF, 0xA3])) // Matroska EBML header; the DocType says WebM or Matroska
        {
            var head = bytes.AsSpan(0, Math.Min(64, bytes.Length));
            return head.IndexOf("webm"u8) >= 0 ? "webm" : "mkv";
        }
        if (StartsText("RIFF") && StartsText("AVI ", 8)) return "avi";
        if (StartsText("FLV") && bytes.Length >= 4 && bytes[3] == 1) return "flv";
        if (Starts([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C]))
        {
            return "wmv"; // ASF header object
        }
        if (Starts([0x00, 0x00, 0x01, 0xBA]) || Starts([0x00, 0x00, 0x01, 0xB3])) return "mpg";

        // Archives
        if (Starts([0x1F, 0x8B])) return "tgz";
        if (StartsText("BZh") && bytes.Length >= 4 && bytes[3] >= (byte)'1' && bytes[3] <= (byte)'9') return "tbz2";
        if (Starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])) return "txz";
        if (Starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])) return "7z";
        if (Starts([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07])) return "rar";
        if (StartsText("ustar", 257)) return "tar";

        // Databases and 3D models
        if (StartsText("SQLite format 3\0")) return "sqlite";
        if (StartsText("PXR-USDC")) return "usdc";
        if (StartsText("#usda ")) return "usda";
        if (StartsText("ply") && bytes.Length > 3 && bytes[3] is 0x20 or 0x0A or 0x0D) return "ply";
        if (StartsText("Ogawa")) return "abc";

        // ISO base media (HEIF images and MP4-family audio/video)
        if (StartsText("ftyp", 4) && bytes.Length >= 12)
        {
            var brand = Encoding.UTF8.GetString(bytes, 8, 4);
            switch (brand)
            {
                case "avif" or "avis": return "avif";
                case "heic" or "heix" or "heim" or "heis" or "mif1": return "heic";
                case "hevc" or "hevx" or "msf1": return "heics";
                case "crx ": return "raw"; // Canon CR3
                case "M4A " or "M4B " or "M4P ": return "m4a";
                case "M4V " or "M4VH" or "M4VP": return "m4v";
                case "qt  ": return "mov";
                case "isom" or "iso2" or "iso4" or "iso5" or "iso6" or "mp41" or "mp42" or "avc1" or "dash" or "MSNV":
                    return "mp4";
                default:
                    return brand.StartsWith("3gp", StringComparison.Ordinal) || brand.StartsWith("3g2", StringComparison.Ordinal)
                        ? "3gp" : null;
            }
        }
        if (StartsText("moov", 4) || StartsText("mdat", 4) || StartsText("wide", 4)) return "mov";
        return null;
    }
}
