using System.Text.Json;
using System.Text.Json.Serialization;

namespace Ameya.Core.Conversion;

/// <summary>
/// User-tunable settings for one conversion. The JSON shape matches the Mac's ConversionOptions,
/// so a request written by either app can be read by either worker. Tool settings that no Windows
/// engine uses yet (image, video, pdf, passport and text edits) are carried as raw JSON.
/// </summary>
public sealed class ConversionOptions
{
    public const int DefaultMaxPixels = 100_000_000;
    public const int DefaultMaxFrames = 1_000;

    /// <summary>0…1 for lossy formats. Null uses the format default.</summary>
    public double? Quality { get; set; }
    /// <summary>Hard cap on decoded pixels per frame, against decompression bombs.</summary>
    public int MaxPixels { get; set; } = DefaultMaxPixels;
    /// <summary>Upper bound on pages or frames read from one file.</summary>
    public int MaxFrames { get; set; } = DefaultMaxFrames;
    public int? RasterLongSide { get; set; }
    public JsonElement? Image { get; set; }
    public JsonElement? Video { get; set; }
    public JsonElement? Pdf { get; set; }
    public JsonElement? Text { get; set; }
    public JsonElement? Passport { get; set; }
    public string? Language { get; set; }
    public int? SubtitleShiftMilliseconds { get; set; }
    public double? SubtitleFrameRate { get; set; }
    /// <summary>Set by the runner when a password follows on stdin, ahead of the file (WorkerSecret).</summary>
    public bool? SecretOnStdin { get; set; }

    // Test hooks. Only honoured by Debug builds of the worker.
    public double? DebugDelaySeconds { get; set; }
    public bool? DebugCrash { get; set; }
    /// <summary>Windows only: the worker starts a long-running child of itself, to test that
    /// stopping a job stops everything it started.</summary>
    public bool? DebugSpawnChild { get; set; }
    /// <summary>Windows only: the worker's output is a JSON report of its own sandbox.</summary>
    public bool? DebugReportSandbox { get; set; }
}

/// <summary>What the app asks the worker to do. Sent as JSON on the worker's command line.</summary>
public sealed class ConversionRequest
{
    /// <summary>The source format id as detected by the app (the worker never sees file names).</summary>
    public string? Source { get; set; }
    public string Target { get; set; } = "";
    public ConversionOptions Options { get; set; } = new();
    /// <summary>Formats of every input when there is more than one (stdin is then a TAR stream).</summary>
    public List<string>? Inputs { get; set; }
}

/// <summary>What the worker reports back after a successful conversion.</summary>
public sealed class ConversionResult
{
    /// <summary>Total bytes written to stdout (for several files, the size of the TAR stream).</summary>
    public long OutputBytes { get; set; }
    public int Frames { get; set; }
    /// <summary>Note ids (see the spec's notes) describing what actually happened.</summary>
    public List<string> Notes { get; set; } = [];
    /// <summary>Set when the job produced several files: their names, in order. stdout is then a TAR stream.</summary>
    public List<string>? OutputNames { get; set; }
}

/// <summary>JSON settings shared by both ends of the worker protocol.</summary>
public static class ProtocolJson
{
    public static JsonSerializerOptions Options { get; } = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };
}
