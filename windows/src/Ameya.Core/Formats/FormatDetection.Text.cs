using System.Text;
using System.Text.RegularExpressions;

namespace Ameya.Core.Formats;

public enum SvgRootKind
{
    /// <summary>The first element is &lt;svg.</summary>
    Svg,
    /// <summary>The first element is something else, or the bytes are not XML text.</summary>
    Other,
    /// <summary>The bytes end before the first element (inside the prolog).</summary>
    Undetermined,
}

public readonly record struct SvgRootScan(SvgRootKind Kind, int Offset = 0);

public static partial class FormatDetection
{
    private const RegexOptions Pattern = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;

    [GeneratedRegex(@"^(<\?xml[^>]*\?>\s*)?(<!--.*?-->\s*)*<([a-z0-9_]+:)?tt[\s>]", Pattern)]
    private static partial Regex TtmlRoot();

    [GeneratedRegex(@"^\d+:\d{2}:\d{2}\.\d{3},\d+:\d{2}:\d{2}\.\d{3}\s*$", Pattern)]
    private static partial Regex SbvTiming();

    [GeneratedRegex(@"^\{\d+\}\{\d*\}", Pattern)]
    private static partial Regex MicroDvdLine();

    [GeneratedRegex(@"^\[(\d+:\d{1,2}([.:]\d{1,3})?|(ar|ti|al|au|by|offset|length|re|ve|la|id|#|tool|lr|kana):[^\]]*)\]", Pattern)]
    private static partial Regex LrcTag();

    /// <summary>ASS/SSA, TTML/DFXP and SAMI: subtitle formats with an unmistakable opening.</summary>
    private static string? SniffSubtitleSignature(byte[] bytes)
    {
        var text = LeadingText(bytes);
        if (text.StartsWith("[script info]", StringComparison.Ordinal))
        {
            if (text.Contains("scripttype: v4.00+", StringComparison.Ordinal) || text.Contains("[v4+ styles]", StringComparison.Ordinal)) return "ass";
            if (text.Contains("scripttype: v4.00", StringComparison.Ordinal) || text.Contains("[v4 styles]", StringComparison.Ordinal)) return "ssa";
            return null; // ASS or SSA: the extension decides in SniffSubtitleText
        }
        if (text.StartsWith("<sami", StringComparison.Ordinal)) return "smi";
        if (text.StartsWith('<') && TtmlRoot().IsMatch(text)) return "ttml";
        return null;
    }

    /// <summary>SBV, MicroDVD and LRC are recognised by their first line. These patterns are weaker,
    /// so they only apply when the extension is a subtitle one or missing.</summary>
    private static string? SniffSubtitleText(byte[] bytes, string? byExtension)
    {
        if (byExtension is not null && Catalog.Get(byExtension).Family != "subtitle") return null;
        var text = LeadingText(bytes);
        if (text.StartsWith("[script info]", StringComparison.Ordinal)) return byExtension == "ssa" ? "ssa" : "ass";
        var firstLine = text.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        if (firstLine is null) return null;
        if (SbvTiming().IsMatch(firstLine)) return "sbv";
        if (MicroDvdLine().IsMatch(firstLine)) return "sub";
        if (LrcTag().IsMatch(firstLine)) return "lrc";
        return null;
    }

    /// <summary>The first bytes as lowercased text, without a BOM or surrounding whitespace, with LF line endings.</summary>
    private static string LeadingText(byte[] bytes)
    {
        var body = StartsWith(bytes, [0xEF, 0xBB, 0xBF]) ? bytes[3..] : bytes;
        string decoded;
        if (StartsWith(body, [0xFF, 0xFE]))
        {
            decoded = (body.Length - 2) % 2 == 0 ? Encoding.Unicode.GetString(body, 2, body.Length - 2) : "";
        }
        else if (StartsWith(body, [0xFE, 0xFF]))
        {
            decoded = (body.Length - 2) % 2 == 0 ? Encoding.BigEndianUnicode.GetString(body, 2, body.Length - 2) : "";
        }
        else
        {
            if (Array.IndexOf(body, (byte)0) >= 0) return "";
            decoded = Encoding.UTF8.GetString(body);
        }
        return decoded.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Trim().ToLowerInvariant();
    }

    /// <summary>Finds the root element of XML text, skipping a BOM, the XML declaration, processing
    /// instructions, comments, whitespace and a DOCTYPE (with an internal subset). UTF-16 needs a BOM.</summary>
    public static SvgRootScan SvgRoot(byte[] bytes)
    {
        var text = bytes;
        if (StartsWith(bytes, [0xFF, 0xFE]) || StartsWith(bytes, [0xFE, 0xFF]))
        {
            var encoding = bytes[0] == 0xFF ? Encoding.Unicode : Encoding.BigEndianUnicode;
            var evenLength = (bytes.Length - 2) & ~1;
            text = Encoding.UTF8.GetBytes(encoding.GetString(bytes, 2, evenLength));
        }
        else if (StartsWith(bytes, [0xEF, 0xBB, 0xBF]))
        {
            text = bytes[3..];
        }
        if (Array.IndexOf(text, (byte)0) >= 0) return new(SvgRootKind.Other);

        bool Has(string prefix, int at) => StartsWith(text, Encoding.UTF8.GetBytes(prefix), at);
        int? Find(string needle, int from)
        {
            var found = text.AsSpan(Math.Min(from, text.Length)).IndexOf(Encoding.UTF8.GetBytes(needle));
            return found < 0 ? null : from + found;
        }
        static bool IsSpace(byte b) => b is 0x20 or 0x09 or 0x0A or 0x0D;

        var index = 0;
        while (index < text.Length)
        {
            var b = text[index];
            if (IsSpace(b)) { index++; continue; }
            if (b != (byte)'<') return new(SvgRootKind.Other);
            if (index + 1 >= text.Length) return new(SvgRootKind.Undetermined);
            if (Has("<?", index))
            {
                if (Find("?>", index + 2) is not { } end) return new(SvgRootKind.Undetermined);
                index = end + 2;
            }
            else if (Has("<!--", index))
            {
                if (Find("-->", index + 4) is not { } end) return new(SvgRootKind.Undetermined);
                index = end + 3;
            }
            else if (Has("<!", index))
            {
                if (text.Length < index + 9) return new(SvgRootKind.Undetermined);
                if (Encoding.UTF8.GetString(text, index, 9).ToUpperInvariant() != "<!DOCTYPE") return new(SvgRootKind.Other);
                // Skip to the closing '>', stepping over an internal subset in [...] and quoted strings.
                var position = index + 9;
                var inSubset = false;
                byte? quote = null;
                while (position < text.Length)
                {
                    var c = text[position];
                    if (quote is { } open) { if (c == open) quote = null; }
                    else if (c is (byte)'"' or (byte)'\'') quote = c;
                    else if (c == (byte)'[') inSubset = true;
                    else if (c == (byte)']') inSubset = false;
                    else if (c == (byte)'>' && !inSubset) break;
                    position++;
                }
                if (position >= text.Length) return new(SvgRootKind.Undetermined);
                index = position + 1;
            }
            else
            {
                // The root element. Accept <svg and a namespace prefix such as <svg:svg.
                var nameEnd = index + 1;
                while (nameEnd < text.Length && !IsSpace(text[nameEnd]) && text[nameEnd] != (byte)'>' && text[nameEnd] != (byte)'/')
                {
                    nameEnd++;
                }
                if (nameEnd >= text.Length) return new(SvgRootKind.Undetermined);
                var name = Encoding.UTF8.GetString(text, index + 1, nameEnd - index - 1);
                var local = name.Split(':', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? name;
                return local == "svg" ? new(SvgRootKind.Svg, index) : new(SvgRootKind.Other);
            }
        }
        return new(SvgRootKind.Undetermined);
    }

    /// <summary>True when the bytes have no NULs, start with a UTF-16 BOM, or look like UTF-16
    /// without one (NULs only in every other byte, as in mostly-Latin UTF-16 text).</summary>
    internal static bool LooksLikeText(byte[] bytes)
    {
        if (bytes.Length == 0) return true;
        if (StartsWith(bytes, [0xFF, 0xFE]) || StartsWith(bytes, [0xFE, 0xFF])) return true;
        if (Array.IndexOf(bytes, (byte)0) < 0) return true;
        int even = 0, odd = 0;
        for (var i = 0; i < bytes.Length; i++)
        {
            if (bytes[i] != 0) continue;
            if (i % 2 == 0) even++; else odd++;
        }
        var pairs = bytes.Length / 2;
        return pairs >= 2 && (even == 0 || odd == 0) && Math.Max(even, odd) * 3 >= pairs;
    }

    /// <summary>A JSON file whose opening bytes name a GeoJSON object type.</summary>
    private static bool LooksLikeGeoJson(byte[] bytes)
    {
        var head = new string(Encoding.UTF8.GetString(bytes).Where(c => !char.IsWhiteSpace(c)).ToArray());
        return head.Contains("\"type\":\"FeatureCollection\"", StringComparison.Ordinal)
            || (head.Contains("\"type\":\"Feature\"", StringComparison.Ordinal) && head.Contains("\"geometry\"", StringComparison.Ordinal));
    }
}
