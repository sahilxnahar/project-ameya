using System.Text.Json;

namespace Ameya.Core.Formats;

/// <summary>One conversion the shared spec allows, and what it may lose.</summary>
public sealed record Route(FileFormat From, FileFormat To, bool NeedsFFmpeg, IReadOnlyList<string> PossibleLosses);

/// <summary>
/// Every format, family timeout, note message and route from spec/formats.json, which is embedded
/// in this assembly. The Mac app generates that file from its own code, so this catalog is the
/// single source of truth for "which conversions exist" on both platforms. Windows narrows it
/// further with its own capability check (see ConversionMatrix) but never adds to it.
/// </summary>
public sealed class FormatCatalog
{
    private static readonly Lazy<FormatCatalog> SharedCatalog = new(LoadEmbedded);

    private readonly Dictionary<string, FileFormat> _byId;
    private readonly Dictionary<string, FileFormat> _byExtension;
    private readonly Dictionary<(string, string), Route> _routes;
    private readonly Dictionary<string, TimeSpan> _timeouts;
    private readonly Dictionary<string, string> _notes;

    private FormatCatalog(SpecDocument spec)
    {
        if (spec.Version != 1) throw new InvalidDataException($"Unsupported spec version {spec.Version}.");
        All = spec.Formats.Select(f => new FileFormat(f)).ToList();
        _byId = All.ToDictionary(f => f.Id, StringComparer.Ordinal);
        // Like the Mac's fromExtension: the first format (in spec order) listing the extension wins.
        _byExtension = new Dictionary<string, FileFormat>(StringComparer.Ordinal);
        foreach (var format in All)
        {
            foreach (var ext in format.Extensions) _byExtension.TryAdd(ext, format);
        }
        _timeouts = spec.Families.ToDictionary(f => f.Id, f => TimeSpan.FromSeconds(f.TimeoutSeconds), StringComparer.Ordinal);
        _notes = spec.Notes.ToDictionary(n => n.Id, n => n.Message, StringComparer.Ordinal);
        Routes = spec.Routes.Select(r => new Route(Get(r.From), Get(r.To), r.NeedsFFmpeg, r.PossibleLosses)).ToList();
        _routes = Routes.ToDictionary(r => (r.From.Id, r.To.Id));
    }

    /// <summary>The catalog embedded in this build.</summary>
    public static FormatCatalog Shared => SharedCatalog.Value;

    /// <summary>All formats, in the Mac's order (which is also the order targets are shown in).</summary>
    public IReadOnlyList<FileFormat> All { get; }

    public IReadOnlyList<Route> Routes { get; }

    public IReadOnlyCollection<string> NoteIds => _notes.Keys;

    public static FormatCatalog Parse(string json)
    {
        var spec = JsonSerializer.Deserialize<SpecDocument>(json) ?? throw new InvalidDataException("Empty spec.");
        return new FormatCatalog(spec);
    }

    private static FormatCatalog LoadEmbedded()
    {
        using var stream = typeof(FormatCatalog).Assembly.GetManifestResourceStream("Ameya.spec.formats.json")
            ?? throw new InvalidOperationException("The format spec is missing from this build.");
        using var reader = new StreamReader(stream);
        return Parse(reader.ReadToEnd());
    }

    public FileFormat Get(string id) =>
        _byId.TryGetValue(id, out var format) ? format : throw new KeyNotFoundException($"Unknown format id '{id}'.");

    public FileFormat? Find(string? id) => id is not null && _byId.TryGetValue(id, out var format) ? format : null;

    /// <summary>The format an extension (without the dot, any case) belongs to.</summary>
    public FileFormat? FromExtension(string extension)
    {
        if (string.IsNullOrEmpty(extension)) return null;
        return _byExtension.TryGetValue(extension.ToLowerInvariant(), out var format) ? format : null;
    }

    public Route? FindRoute(FileFormat from, FileFormat to) =>
        _routes.TryGetValue((from.Id, to.Id), out var route) ? route : null;

    /// <summary>How long one job of this family may run before it is stopped.</summary>
    public TimeSpan Timeout(FileFormat format) =>
        _timeouts.TryGetValue(format.Family, out var timeout) ? timeout : TimeSpan.FromMinutes(5);

    /// <summary>The plain-words message for a note id, or the id itself for an unknown note.</summary>
    public string NoteMessage(string noteId) => _notes.TryGetValue(noteId, out var message) ? message : noteId;

    public bool IsKnownNote(string noteId) => _notes.ContainsKey(noteId);
}
