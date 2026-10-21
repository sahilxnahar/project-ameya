using Ameya.Core.Conversion;
using Ameya.Core.Formats;
using Windows.Graphics.Imaging;

namespace Ameya.Engines;

/// <summary>
/// What this PC can convert. Built-in WIC codecs are always there; HEIC, AVIF and WebP come from
/// free Microsoft Store extensions, so they are offered only when Windows lists a decoder for them.
/// Nothing is ever downloaded. The matrix never offers a route the shared spec doesn't have.
/// </summary>
public static class WindowsCapabilities
{
    private static readonly string[] BuiltInReadable = ["jpeg", "png", "tiff", "bmp", "gif", "ico"];
    private static readonly string[] Writable = ["jpeg", "png", "tiff", "bmp", "gif", "ico", "pdf"];

    /// <summary>Format ids implemented on Windows at all (whatever codecs are installed).</summary>
    public static IReadOnlyList<string> ImplementedIds { get; } = [.. BuiltInReadable, "heic", "avif", "webp", "pdf"];

    public static IReadOnlySet<string> ReadableIds()
    {
        var readable = new HashSet<string>(BuiltInReadable, StringComparer.Ordinal);
        try
        {
            foreach (var codec in BitmapDecoder.GetDecoderInformationEnumerator())
            {
                var extensions = codec.FileExtensions.Select(e => e.ToLowerInvariant()).ToHashSet();
                if (extensions.Contains(".heic") || extensions.Contains(".heif")) readable.Add("heic");
                if (extensions.Contains(".avif")) readable.Add("avif");
                if (extensions.Contains(".webp")) readable.Add("webp");
            }
        }
        catch (Exception)
        {
            // If Windows can't list its codecs, offer only the built-in ones.
        }
        return readable;
    }

    public static IReadOnlySet<string> WritableIds() => new HashSet<string>(Writable, StringComparer.Ordinal);

    public static ConversionMatrix Matrix(FormatCatalog? catalog = null)
    {
        catalog ??= FormatCatalog.Shared;
        return new ConversionMatrix(
            catalog,
            ReadableIds().Select(catalog.Get),
            WritableIds().Select(catalog.Get),
            ffmpeg: false);
    }
}
