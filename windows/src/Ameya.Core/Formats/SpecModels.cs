using System.Text.Json.Serialization;

namespace Ameya.Core.Formats;

// The shape of spec/formats.json. Field names match the Swift exporter exactly.

internal sealed class SpecDocument
{
    [JsonPropertyName("version")] public int Version { get; set; }
    [JsonPropertyName("families")] public List<SpecFamily> Families { get; set; } = [];
    [JsonPropertyName("formats")] public List<SpecFormat> Formats { get; set; } = [];
    [JsonPropertyName("notes")] public List<SpecNote> Notes { get; set; } = [];
    [JsonPropertyName("routes")] public List<SpecRoute> Routes { get; set; } = [];
}

internal sealed class SpecFamily
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("timeoutSeconds")] public long TimeoutSeconds { get; set; }
}

internal sealed class SpecFormat
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("displayName")] public string DisplayName { get; set; } = "";
    [JsonPropertyName("family")] public string Family { get; set; } = "";
    [JsonPropertyName("extensions")] public List<string> Extensions { get; set; } = [];
    [JsonPropertyName("preferredExtension")] public string PreferredExtension { get; set; } = "";
    [JsonPropertyName("supportsAlpha")] public bool SupportsAlpha { get; set; }
    [JsonPropertyName("supportsAnimation")] public bool SupportsAnimation { get; set; }
    [JsonPropertyName("supportsPages")] public bool SupportsPages { get; set; }
    [JsonPropertyName("isLossy")] public bool IsLossy { get; set; }
    [JsonPropertyName("isIcon")] public bool IsIcon { get; set; }
    [JsonPropertyName("isTextDocument")] public bool IsTextDocument { get; set; }
    [JsonPropertyName("isFFmpegOnly")] public bool IsFFmpegOnly { get; set; }
    [JsonPropertyName("isFFmpegTarget")] public bool IsFFmpegTarget { get; set; }
    [JsonPropertyName("isReadOnlyMedia")] public bool IsReadOnlyMedia { get; set; }
    [JsonPropertyName("isDataSource")] public bool IsDataSource { get; set; }
    [JsonPropertyName("isCompression")] public bool IsCompression { get; set; }
    [JsonPropertyName("isBookOrComic")] public bool IsBookOrComic { get; set; }
    [JsonPropertyName("isRecognisableImage")] public bool IsRecognisableImage { get; set; }
}

internal sealed class SpecNote
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("message")] public string Message { get; set; } = "";
}

internal sealed class SpecRoute
{
    [JsonPropertyName("from")] public string From { get; set; } = "";
    [JsonPropertyName("to")] public string To { get; set; } = "";
    [JsonPropertyName("needsFFmpeg")] public bool NeedsFFmpeg { get; set; }
    [JsonPropertyName("possibleLosses")] public List<string> PossibleLosses { get; set; } = [];
}
