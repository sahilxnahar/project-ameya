namespace Ameya.Core.Formats;

/// <summary>
/// A file format Ameya knows about. Every format, its names and flags come from the shared spec
/// (spec/formats.json, exported by the Mac app), so both apps always agree on what a format is.
/// Two instances are equal when their ids are equal.
/// </summary>
public sealed class FileFormat : IEquatable<FileFormat>
{
    internal FileFormat(SpecFormat spec)
    {
        Id = spec.Id;
        DisplayName = spec.DisplayName;
        Family = spec.Family;
        Extensions = spec.Extensions;
        PreferredExtension = spec.PreferredExtension;
        SupportsAlpha = spec.SupportsAlpha;
        SupportsAnimation = spec.SupportsAnimation;
        SupportsPages = spec.SupportsPages;
        IsLossy = spec.IsLossy;
        IsIcon = spec.IsIcon;
        IsTextDocument = spec.IsTextDocument;
        IsFFmpegOnly = spec.IsFFmpegOnly;
        IsFFmpegTarget = spec.IsFFmpegTarget;
        IsReadOnlyMedia = spec.IsReadOnlyMedia;
        IsDataSource = spec.IsDataSource;
        IsCompression = spec.IsCompression;
        IsBookOrComic = spec.IsBookOrComic;
        IsRecognisableImage = spec.IsRecognisableImage;
    }

    /// <summary>The stable id shared with the Mac app and used in worker requests, e.g. "jpeg", "7z".</summary>
    public string Id { get; }
    public string DisplayName { get; }
    /// <summary>"image", "document", "audio", … (see the spec's families).</summary>
    public string Family { get; }
    /// <summary>File name extensions without dots, most common first.</summary>
    public IReadOnlyList<string> Extensions { get; }
    public string PreferredExtension { get; }

    public bool SupportsAlpha { get; }
    public bool SupportsAnimation { get; }
    public bool SupportsPages { get; }
    public bool IsLossy { get; }
    public bool IsIcon { get; }
    public bool IsTextDocument { get; }
    public bool IsFFmpegOnly { get; }
    public bool IsFFmpegTarget { get; }
    public bool IsReadOnlyMedia { get; }
    public bool IsDataSource { get; }
    public bool IsCompression { get; }
    public bool IsBookOrComic { get; }
    public bool IsRecognisableImage { get; }

    public bool IsImage => Family == "image";

    public bool Equals(FileFormat? other) => other is not null && other.Id == Id;
    public override bool Equals(object? obj) => obj is FileFormat other && Equals(other);
    public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(Id);
    public override string ToString() => Id;

    public static bool operator ==(FileFormat? left, FileFormat? right) =>
        left is null ? right is null : left.Equals(right);

    public static bool operator !=(FileFormat? left, FileFormat? right) => !(left == right);
}
