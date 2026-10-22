using System.Globalization;
using System.Text.Json;
using Ameya.Core.Conversion;

namespace Ameya.Core.Worker;

/// <summary>
/// The line protocol between the app and the worker process, the same as on the Mac.
/// The worker gets the request as JSON after <c>--request</c>, reads the source from stdin and
/// writes the result to stdout. Status goes to stderr, one line each: <c>AMEYA:progress:&lt;0…1&gt;</c>,
/// then exactly one of <c>AMEYA:done:&lt;ConversionResult JSON&gt;</c> or <c>AMEYA:error:&lt;message&gt;</c>.
/// </summary>
public static class WorkerProtocol
{
    public const string RequestArgument = "--request";
    public const string ProgressPrefix = "AMEYA:progress:";
    public const string DonePrefix = "AMEYA:done:";
    public const string ErrorPrefix = "AMEYA:error:";

    public static string Encode(ConversionRequest request) => JsonSerializer.Serialize(request, ProtocolJson.Options);

    public static ConversionRequest DecodeRequest(string json) =>
        JsonSerializer.Deserialize<ConversionRequest>(json, ProtocolJson.Options) ?? throw new JsonException("Empty request.");

    public static string Encode(ConversionResult result) => JsonSerializer.Serialize(result, ProtocolJson.Options);

    public static ConversionResult DecodeResult(string json) =>
        JsonSerializer.Deserialize<ConversionResult>(json, ProtocolJson.Options) ?? throw new JsonException("Empty result.");

    public static string ProgressLine(double fraction) =>
        ProgressPrefix + Math.Clamp(fraction, 0, 1).ToString("0.000", CultureInfo.InvariantCulture);

    /// <summary>An error line. Newlines would split it, so they become spaces.</summary>
    public static string ErrorLine(string message) => ErrorPrefix + message.ReplaceLineEndings(" ");

    public static bool TryParseProgress(string line, out double fraction)
    {
        fraction = 0;
        if (!line.StartsWith(ProgressPrefix, StringComparison.Ordinal)) return false;
        if (!double.TryParse(line.AsSpan(ProgressPrefix.Length), NumberStyles.Float, CultureInfo.InvariantCulture, out var value)) return false;
        fraction = Math.Clamp(value, 0, 1);
        return true;
    }

    /// <summary>Quotes one argument for a Windows command line so CommandLineToArgvW (and .NET's
    /// Main) reads it back exactly: backslashes before a quote, and before the closing quote, double.</summary>
    public static string QuoteArgument(string argument)
    {
        if (argument.Length > 0 && argument.IndexOfAny([' ', '\t', '\n', '\v', '"']) < 0) return argument;
        var builder = new System.Text.StringBuilder("\"");
        var backslashes = 0;
        foreach (var c in argument)
        {
            if (c == '\\') { backslashes++; continue; }
            if (c == '"')
            {
                builder.Append('\\', backslashes * 2 + 1).Append('"');
            }
            else
            {
                builder.Append('\\', backslashes).Append(c);
            }
            backslashes = 0;
        }
        builder.Append('\\', backslashes * 2).Append('"');
        return builder.ToString();
    }
}
