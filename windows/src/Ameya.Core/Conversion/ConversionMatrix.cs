using Ameya.Core.Formats;

namespace Ameya.Core.Conversion;

/// <summary>
/// Which conversions are offered on this PC, and what may be lost, before anything runs.
/// Routes come only from the shared spec; this PC's engines can narrow them (fewer readable or
/// writable formats, no FFmpeg yet) but can never add a route the spec doesn't have.
/// </summary>
public sealed class ConversionMatrix
{
    private readonly FormatCatalog _catalog;
    private readonly HashSet<FileFormat> _readable;
    private readonly HashSet<FileFormat> _writable;
    private readonly bool _ffmpeg;

    /// <param name="readable">Formats this PC can decode.</param>
    /// <param name="writable">Formats this PC can encode.</param>
    /// <param name="ffmpeg">Whether the FFmpeg helper is present (not yet on Windows).</param>
    public ConversionMatrix(FormatCatalog catalog, IEnumerable<FileFormat> readable, IEnumerable<FileFormat> writable, bool ffmpeg = false)
    {
        _catalog = catalog;
        _readable = [.. readable];
        _writable = [.. writable];
        _ffmpeg = ffmpeg;
    }

    /// <summary>Whether the shared spec has an engine for this pair, whatever this PC can do.</summary>
    public static bool CanConvert(FormatCatalog catalog, FileFormat source, FileFormat target, bool ffmpeg) =>
        catalog.FindRoute(source, target) is { } route && (ffmpeg || !route.NeedsFFmpeg);

    public bool CanRead(FileFormat format) => _readable.Contains(format);

    /// <summary>Whether this PC can run the conversion.</summary>
    public bool IsOffered(FileFormat source, FileFormat target) =>
        _readable.Contains(source) && _writable.Contains(target) && CanConvert(_catalog, source, target, _ffmpeg);

    /// <summary>Targets offered for one source, in the Mac's display order. Never the source itself.</summary>
    public IReadOnlyList<FileFormat> Targets(FileFormat source) =>
        _catalog.All.Where(target => target != source && IsOffered(source, target)).ToList();

    /// <summary>Targets every one of the given sources can be converted to.</summary>
    public IReadOnlyList<FileFormat> CommonTargets(IReadOnlyList<FileFormat> sources)
    {
        if (sources.Count == 0) return [];
        IEnumerable<FileFormat> common = Targets(sources[0]);
        foreach (var source in sources.Skip(1))
        {
            var allowed = Targets(source).ToHashSet();
            common = common.Where(allowed.Contains).ToList();
        }
        return common.ToList();
    }

    /// <summary>Note ids for losses that may happen. The worker reports what actually happened.</summary>
    public IReadOnlyList<string> PossibleLosses(FileFormat source, FileFormat target) =>
        _catalog.FindRoute(source, target)?.PossibleLosses ?? [];
}
