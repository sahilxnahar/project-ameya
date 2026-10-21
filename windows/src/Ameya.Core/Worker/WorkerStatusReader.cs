using System.Text;
using Ameya.Core.Conversion;

namespace Ameya.Core.Worker;

/// <summary>
/// Reads the worker's stderr status lines. The worker parses untrusted files, so its output is
/// treated as untrusted too: lines are capped in length and anything unexpected is a protocol problem.
/// </summary>
internal sealed class WorkerStatusReader(IProgress<double>? progress)
{
    private const int MaxLineBytes = 1 << 20;

    public ConversionResult? Result { get; private set; }
    public string? ErrorMessage { get; private set; }
    public string? ProtocolProblem { get; private set; }

    public async Task ReadAsync(Stream stderr)
    {
        var buffer = new byte[8192];
        var line = new MemoryStream();
        var overflowed = false;
        int read;
        while ((read = await stderr.ReadAsync(buffer).ConfigureAwait(false)) > 0)
        {
            for (var i = 0; i < read; i++)
            {
                if (buffer[i] == (byte)'\n')
                {
                    if (!overflowed) Handle(Encoding.UTF8.GetString(line.GetBuffer(), 0, (int)line.Length).TrimEnd('\r'));
                    line.SetLength(0);
                    overflowed = false;
                }
                else if (line.Length < MaxLineBytes)
                {
                    line.WriteByte(buffer[i]);
                }
                else if (!overflowed)
                {
                    overflowed = true;
                    ProtocolProblem ??= "a status line was too long";
                }
            }
        }
        if (line.Length > 0 && !overflowed) Handle(Encoding.UTF8.GetString(line.GetBuffer(), 0, (int)line.Length).TrimEnd('\r'));
    }

    private void Handle(string line)
    {
        if (WorkerProtocol.TryParseProgress(line, out var fraction))
        {
            progress?.Report(fraction);
        }
        else if (line.StartsWith(WorkerProtocol.DonePrefix, StringComparison.Ordinal))
        {
            try
            {
                Result = WorkerProtocol.DecodeResult(line[WorkerProtocol.DonePrefix.Length..]);
            }
            catch (System.Text.Json.JsonException)
            {
                ProtocolProblem ??= "unreadable result";
            }
        }
        else if (line.StartsWith(WorkerProtocol.ErrorPrefix, StringComparison.Ordinal))
        {
            ErrorMessage = line[WorkerProtocol.ErrorPrefix.Length..];
        }
        // Anything else (for example a runtime message) is ignored, as on the Mac.
    }
}
